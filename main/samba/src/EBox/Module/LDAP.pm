# Copyright (C) 2005-2007 Warp Networks S.L.
# Copyright (C) 2008-2014 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
use strict;
use warnings;

package EBox::Module::LDAP;
use base qw(EBox::Module::Service);

use EBox::Gettext;
use EBox::Exceptions::External;
use EBox::Exceptions::Internal;
use EBox::Exceptions::NotImplemented;
use EBox::Exceptions::MissingArgument;
use EBox::Exceptions::LDAP;

use EBox::Samba::FSMO;
use EBox::Samba::AuthKrbHelper;
use EBox::Samba::LdapObject;
use Net::LDAP;
use Net::LDAP::Util qw(ldap_explode_dn canonical_dn);
use Net::LDAP::LDIF;
use File::Temp;
use File::Slurp;
use Authen::SASL;

use TryCatch::Lite;

# Method: _ldapModImplementation
#
#   All modules using any of the functions in LdapUserBase.pm
#   should override this method to return the implementation
#   of that interface.
#
# Returns:
#
#       An object implementing EBox::LdapUserBase
sub _ldapModImplementation
{
    throw EBox::Exceptions::NotImplemented();
}

# Method: ldap
#
#   Provides an EBox::Ldap object with the proper configuration for the
#   LDAP setup of this ebox
#
sub ldap
{
    my ($self) = @_;

    unless(defined($self->{ldap})) {
        $self->{ldap} = $self->global()->modInstance('samba')->newLDAP();
    }
    return $self->{ldap};
}

sub clearLdapConn
{
    my ($self) = @_;
    $self->{ldap} or return;
    $self->{ldap}->clearConn();
    $self->{ldap} = undef;
}

sub _connectToSchemaMaster
{
    my ($self) = @_;

    my $fsmo = new EBox::Samba::FSMO();
    my $ntdsOwner = $fsmo->getSchemaMaster();
    my $ntdsParts = ldap_explode_dn($ntdsOwner);
    shift @{$ntdsParts};
    my $serverOwner = canonical_dn($ntdsParts);

    my $params = {
        base => $serverOwner,
        scope => 'base',
        filter => '(objectClass=*)',
        attrs => ['dnsHostName'],
    };
    my $result = $self->ldap->search($params);
    if ($result->count() != 1) {
        throw EBox::Exceptions::Internal(
            __x("Error on search: Expected one entry, got {x}.\n",
                x => $result->count()));
    }
    my $entry = $result->entry(0);
    my $dnsOwner = $entry->get_value('dnsHostName');

    my $masterLdap = new Net::LDAP($dnsOwner);
    unless ($masterLdap) {
        throw EBox::Exceptions::Internal(
            __x('Error connectiong to schema master role owner ({x})',
                x => $dnsOwner));
    }

    # Bind with schema operator privilege
    my $krbHelper = new EBox::Samba::AuthKrbHelper(RID => 500);
    my $sasl = new Authen::SASL(mechanism => 'GSSAPI');
    unless ($sasl) {
        throw EBox::Exceptions::External(
            __x("Unable to setup SASL object: {x}",
                x => $@));
    }
    # Workaround for hostname canonicalization
    my $saslClient = $sasl->client_new('ldap', $dnsOwner);
    unless ($saslClient) {
        throw EBox::Exceptions::External(
            __x("Unable to create SASL client: {x}",
                x => $@));
    }

    # Check GSSAPI support
    my $dse = $masterLdap->root_dse(attrs => ['defaultNamingContext', '*']);
    unless ($dse->supported_sasl_mechanism('GSSAPI')) {
        throw EBox::Exceptions::External(
            __("AD LDAP server does not support GSSAPI"));
    }

    # Finally bind to LDAP using our SASL object
    my $masterBind = $masterLdap->bind(sasl => $saslClient);
    if ($masterBind->is_error()) {
        throw EBox::Exceptions::LDAP(
            message => __('Error binding to schama master LDAP:'),
            result => $masterBind);
    }

    return $masterLdap;
}

sub _sendSchemaUpdate
{
    my ($self, $masterLdap, $ldifTemplate) = @_;

    unless (defined $masterLdap) {
        throw EBox::Exceptions::MissingArgument('masterLdap');
    }
    unless (defined $ldifTemplate) {
        throw EBox::Exceptions::MissingArgument('ldifTemplate');
    }

    # Mangle LDIF
    my $defaultNC = $self->ldap->dn();
    my $fh = new File::Temp(DIR => EBox::Config::tmp());
    my $ldifFile = $fh->filename();
    my $buffer = File::Slurp::read_file($ldifTemplate);
    $buffer =~ s/DOMAIN_TOP_DN/$defaultNC/g;
    File::Slurp::write_file($ldifFile, $buffer);

    # Send update
    my $ldif = new Net::LDAP::LDIF($ldifFile, 'r', onerror => 'die');
    while (not $ldif->eof()) {
        my $entry = $ldif->read_entry();
        if ($ldif->error()) {
            throw EBox::Exceptions::Internal(
                __x('Error loading LDIF. Error message: {x}, Error lines: {y}',
                    x => $ldif->error(), y => $ldif->error_lines()));
        } else {
            # Skip if already extended
            my $dn = $entry->dn();
            # Skip checking the update schema cache sent to root DSE
            if ($dn ne '') {
                my $result = $masterLdap->search(
                    base => $dn,
                    scope => 'base',
                    filter => '(objectClass=*)');
                next if ($result->count() > 0);
            }

            # Send the entry
            EBox::info("Sending schema update: $dn");
            my $msg = $entry->update($masterLdap);
            if ($msg->is_error()) {
                throw EBox::Exceptions::LDAP(
                    message => __("Error sending schema update: $dn"),
                    result => $msg);
            }
        }
    }
    $ldif->done();
}

# Method: _loadSchemas
#
#  Load the schema-*.ldif schemas contained in the module package
#
sub _loadSchemas
{
    my ($self) = @_;

    # Locate and connect to schema master
    my $masterLdap = $self->_connectToSchemaMaster();

    my $name = $self->name();
    my $path = EBox::Config::share() . "zentyal-$name";
    foreach my $ldif (glob ("$path/schema-*.ldif")) {
        $self->_sendSchemaUpdate($masterLdap, $ldif);
    }

    my $timeout = 30;
    my $defaultNC = $self->ldap->dn();
    # Wait for schemas replicated if we are not the master
    foreach my $ldif (glob ("$path/schema-*.ldif")) {
        my @lines = read_file($ldif);
        foreach my $line (@lines) {
            my ($dn) = $line =~ /^dn: (.*)/;
            if ($dn) {
                $dn =~ s/DOMAIN_TOP_DN/$defaultNC/;
                EBox::info("Waiting for schema object present: $dn");
                while (1) {
                    my $object = new EBox::Samba::LdapObject(dn => $dn);
                    if ($object->exists()) {
                        last;
                    } else {
                        sleep (1);
                        $timeout--;
                        if ($timeout == 0) {
                            throw EBox::Exceptions::Internal("Schema object $dn not found after 30 seconds");
                        }
                    }
                }
            }
        }
    }
}

# Method: _regenConfig
#
#   Overrides <EBox::Module::Service::_regenConfig>
#
sub _regenConfig
{
    my $self = shift;

    return unless $self->configured();

    if ($self->global()->modInstance('samba')->isProvisioned()) {
        $self->_performSetup();
        $self->SUPER::_regenConfig(@_);
    }
}

sub _performSetup
{
    my ($self) = @_;

    my $state = $self->get_state();
    unless ($state->{'_schemasAdded'}) {
        $self->_loadSchemas();
        $state->{'_schemasAdded'} = 1;
        $self->set_state($state);
    }

    unless ($state->{'_ldapSetup'}) {
        $self->setupLDAP();
        $state->{'_ldapSetup'} = 1;
        $self->set_state($state);
    }
}

sub setupLDAP
{
}

sub setupLDAPDone
{
    my ($self) = @_;
    my $state = $self->get_state();
    return $state->{'_schemasAdded'} and $state->{'_ldapSetup'};
}

# Method: reprovisionLDAP
#
#   Reprovision LDAP setup for the module.
#
sub reprovisionLDAP
{
}

# Method: slaveSetup
#
#  this is called when the slave setup. The slave setup is done when saving
#  changes so this is normally used to modify LDAP or other tasks which don't
#  change configuration.
#
#  The default implementation just calls reprovisionLDAP
#
# For changing configuration before the save changes we will use the
# preSlaveSetup methos which currently is only called for module mail
sub slaveSetup
{
    my ($self) = @_;
    $self->reprovisionLDAP();
}

# Method: preSlaveSetup
#
#  This is called to made change in the module when the server
#  is configured to enter in slave mode. Configuration changes
#  should be done there and will be committed in the next saving of changes.
#
# Parameters:
#  master - master type
#
sub preSlaveSetup
{
    my ($self, $master) = @_;
}

# Method: preSlaveSetup
#
# This method can be used to put a warning to be seen by the administrator
# before setting slave mode. The module should warn of nay destructive action
# entailed by the change of mode.
#
# Parameters:
#  master -master type
#
sub slaveSetupWarning
{
    my ($self, $master) = @_;
    return undef;
}

sub usersModesAllowed
{
    my ($self) = @_;
    my $users = $self->global()->modInstance('samba');
    return [$users->STANDALONE_MODE()];
}

sub checkUsersMode
{
    my ($self) = @_;
    my $users = $self->global()->modInstance('samba');
    my $mode = $users->mode();
    my $allowedMode = grep {
        $mode eq $_
    } @{ $self->usersModesAllowed() };
    if (not $allowedMode) {
        throw EBox::Exceptions::External(__x(
            'Module {mod} is uncompatible with the current users operation mode ({mode})',
            mod => $self->printableName(),
            mode => $users->model('Mode')->modePrintableName,
        ));
    }
}

1;
