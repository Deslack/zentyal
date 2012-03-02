# Copyright (C) 2012 eBox Technologies S.L.
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

package EBox::Samba;

use strict;
use warnings;

#use base qw(EBox::Module::Service EBox::LdapModule EBox::FirewallObserver
#            EBox::Report::DiskUsageProvider EBox::Model::CompositeProvider
#            EBox::Model::ModelProvider EBox::LogObserver);
use base qw(EBox::Module::Service EBox::Model::CompositeProvider EBox::Model::ModelProvider
            EBox::FirewallObserver EBox::LdapModule);

use EBox::Sudo;
use EBox::Global;
use EBox::Service;
use EBox::SambaLdapUser;
#use EBox::UsersAndGroups;
use EBox::Network;
use EBox::SambaFirewall;
#use EBox::SambaLogHelper;
use EBox::Dashboard::Widget;
use EBox::Dashboard::List;
use EBox::Menu::Item;
use EBox::Exceptions::InvalidData;
use EBox::Exceptions::Internal;
use EBox::Exceptions::DataExists;
use EBox::Exceptions::DataMissing;
use EBox::Exceptions::External;
use EBox::Gettext;
use EBox::Config;
use EBox::Model::ModelManager;
use EBox::DBEngineFactory;

use EBox::Ldb;

use Net::Domain qw(hostdomain);
use Sys::Hostname;
use Error qw(:try);

use constant SAMBATOOL            => '/usr/bin/samba-tool';
use constant SAMBAPROVISION       => '/usr/share/samba/setup/provision';
use constant SAMBACONFFILE        => '/etc/samba/smb.conf';
use constant SAMBADNSZONE         => '/var/lib/samba/private/named.conf';
use constant SAMBADNSKEYTAB       => '/var/lib/samba/private/dns.keytab';
use constant SAMBADNSAPPARMOR     => '/etc/apparmor.d/local/usr.sbin.named';
use constant FSTAB_FILE           => '/etc/fstab';
use constant SAMBA_DIR            => '/home/ebox/samba';
use constant SYSVOL_DIR           => '/var/lib/samba/sysvol';
use constant SHARES_DIR           => SAMBA_DIR . '/shares';
use constant PROFILES_DIR         => SAMBA_DIR . '/profiles';
use constant LOGON_SCRIPT         => 'logon.bat';
use constant LOGON_DEFAULT_SCRIPT => 'zentyal-logon.bat';

my $PORTS = [
    { # kerberos
        'protocol' => 'tcp/udp',
        'sourcePort' => 'any',
        'destinationPort' => '88',
    },
    { # DCE endpoint resolution
        'protocol' => 'tcp',
        'sourcePort' => 'any',
        'destinationPort' => '135',
    },
    { # netbios-ns
        'protocol' => 'udp',
        'sourcePort' => 'any',
        'destinationPort' => '137',
    },
    { # netbios-dgm
        'protocol' => 'udp',
        'sourcePort' => 'any',
        'destinationPort' => '138',
    },
    { # netbios-ssn
        'protocol' => 'tcp',
        'sourcePort' => 'any',
        'destinationPort' => '139',
    },
    { # samba LDAP
        'protocol' => 'tcp/udp',
        'sourcePort' => 'any',
        'destinationPort' => '389',
    },
    { # microsoft-ds
        'protocol' => 'tcp',
        'sourcePort' => 'any',
        'destinationPort' => '445',
    },
    { # kerberos change/set password
        'protocol' => 'tcp/udp',
        'sourcePort' => 'any',
        'destinationPort' => '464',
    },
    { # LDAP over TLS/SSL
        'protocol' => 'tcp',
        'sourcePort' => 'any',
        'destinationPort' => '636',
    },
    { # unknown???
        'protocol' => 'tcp',
        'sourcePort' => 'any',
        'destinationPort' => '1024',
    },
    { # msft-gc
        'protocol' => 'tcp',
        'sourcePort' => 'any',
        'destinationPort' => '3268',
    },
    { # msft-gc-ssl
        'protocol' => 'tcp',
        'sourcePort' => 'any',
        'destinationPort' => '3269',
    },
];

sub _create
{
    my $class = shift;
    my $self = $class->SUPER::_create(
        name => 'samba',
        printableName => __n('File Sharing'),
        @_);
    bless ($self, $class);
    return $self;
}

# Method: bootDepends
#
#   Samba depends on CUPS only if printers module enabled.
#
# Overrides:
#
#   <EBox::Module::Base::depends>
#
sub bootDepends
{
    my ($self) = @_;

    my $dependsList = $self->depends();

    if (EBox::Global->modExists('printers')) {
        my $printers = EBox::Global->modInstance('printers');
        if ($printers->isEnabled()) {
            push (@{$dependsList}, 'printers');
        }
    }

    return $dependsList;
}

# Method: appArmorProfiles
#
#   Overrides to set the own AppArmor profile
#
# Overrides:
#
#   <EBox::Module::Base::appArmorProfiles>
#
sub appArmorProfiles
{
    my ($self) = @_;

    my @params = ();
    return [
            {
                'binary' => 'usr.sbin.named',
                'local'  => 1,
                'file'   => 'samba/apparmor-named.local.mas',
                'params' => \@params,
            }
           ];
}

# Method: actions
#
#   Override EBox::Module::Service::actions
#
sub actions
{
    return [
        {
            'action' => __('Create Samba home directory for shares and groups'),
            'reason' => __('Zentyal will create the directories for Samba ' .
                           'shares and groups under /home/samba.'),
            'module' => 'samba',
        },
        {
            'action' => __('Override named apparmor profile'),
            'reason' => __('To allow samba daemon load Active Directory zone'),
            'module' => 'samba',
        },
    ];
}

# Method: usedFiles
#
#   Override EBox::Module::Service::files
#
sub usedFiles
{
    return [
        {
            'file'   => SAMBACONFFILE,
            'reason' => __('To set up Samba according to your configuration.'),
            'module' => 'samba',
        },
        {
            'file'   => FSTAB_FILE,
            'reason' => __('To enable extended attributes and acls.'),
            'module' => 'samba',
        }
    ];
}

# Method: initialSetup
#
# Overrides:
#
#   EBox::Module::Base::initialSetup
#
sub initialSetup
{
    my ($self, $version) = @_;

    # Create default rules and services
    # only if installing the first time
    unless ($version) {
        my $services = EBox::Global->modInstance('services');
        my $serviceName = 'samba';
        unless($services->serviceExists(name => $serviceName)) {
            $services->addMultipleService(
                'name' => $serviceName,
                'printableName' => 'Samba',
                'description' => __('File sharing (Samba) protocol'),
                'internal' => 1,
                'readOnly' => 1,
                'services' => $PORTS,
            );
        }

        my $firewall = EBox::Global->modInstance('firewall');
        $firewall->setInternalService('samba', 'accept');
        $firewall->saveConfigRecursive();
    }
}

# Method: enableActions
#
#   Override EBox::Module::Service::enableActions
#
sub enableActions
{
    my ($self) = @_;

    my @cmds = ();
    push (@cmds, 'mkdir -p ' . SAMBA_DIR);
    push (@cmds, 'mkdir -p ' . PROFILES_DIR);
    EBox::debug("Executing @cmds");
    try {
        EBox::Sudo::root(@cmds);
    } otherwise {
        my $error = shift;
        EBox::debug("Couldn't create directories: $error");
    };

    # Remount filesystem with user_xattr and acl options
    EBox::debug('Setting up filesystem');
    try {
        EBox::Sudo::root(EBox::Config::scripts('samba') . 'setup-filesystem');
    } otherwise {
        my $error = shift;
        EBox::debug("Couldn't setup filesystem options: $error");
    };

    # Disable apparmor profile
    # NOTE This is a temporary fix until ubuntu publish the fix for bug
    #      https://bugs.launchpad.net/ubuntu/+source/bind9/+bug/929563
    EBox::debug('Disabling named apparmor profile');
    @cmds = ('rm -f /etc/apparmor.d/disable/usr.sbin.named',
             'ln -s /etc/apparmor.d/usr.sbin.named /etc/apparmor.d/disable/usr.sbin.named',
             'touch /etc/apparmor.d/local/usr.sbin.named');
    try {
        EBox::Sudo::root(@cmds);
    } otherwise {
        my $error = shift;
        EBox::debug("Couldn't disable named profile: $error");
    };
}

# Method: modelClasses
#
# Overrides:
#
#   <EBox::Model::ModelProvider::modelClasses>
#
sub modelClasses
{

    my ($self) = @_;

    return [
               'EBox::Samba::Model::GeneralSettings',
               'EBox::Samba::Model::SambaShares',
               'EBox::Samba::Model::SambaSharePermissions',
               'EBox::Samba::Model::SambaDeletedShares',
           ];
}

# Method: compositeClasses
#
# Overrides:
#
#   <EBox::Model::CompositeProvider::compositeClasses>
#
sub compositeClasses
{
    my ($self) = @_;

    return [
             'EBox::Samba::Composite::General',
           ];
}

# Method: shares
#
#   It returns the custom shares
#
# Parameters:
#
#     all - return all shares regardless of their permission
#           level. Otherwise shares without permssions or guset access are
#           ignored. Default: false
#
# Returns:
#
#   Array ref containing hash ref with:
#
#   share   - share's name
#   path    - share's path
#   comment - share's comment
#   readOnly  - string containing users and groups with read-only permissions
#   readWrite - string containing users and groups with read and write
#               permissions
#   administrators  - string containing users and groups with admin priviliges
#                     on the share
#   validUsers - readOnly + readWrite + administrators
#
sub shares
{
    my ($self, $all) = @_;

    my $shares = $self->model('SambaShares');
    my @shares = ();

    for my $id (@{$shares->enabledRows()}) {
        my $row = $shares->row($id);
        my @readOnly;
        my @readWrite;
        my @administrators;
        my $shareConf = {};

        my $path = $row->elementByName('path');
        if ($path->selectedType() eq 'zentyal') {
            $shareConf->{'path'} = SHARES_DIR . '/' . $path->value();
        } else {
            $shareConf->{'path'} = $path->value();
        }
        $shareConf->{'share'} = $row->valueByName('share');
        $shareConf->{'comment'} = $row->valueByName('comment');
        $shareConf->{'guest'} = $row->valueByName('guest');

        for my $subId (@{$row->subModel('access')->ids()}) {
            my $subRow = $row->subModel('access')->row($subId);
            my $userType = $subRow->elementByName('user_group');
            my $preCar = '';
            if ($userType->selectedType() eq 'group') {
                $preCar = '@';
            }
            my $user =  $preCar . '"' . $userType->printableValue() . '"';

            my $permissions = $subRow->elementByName('permissions');

            if ($permissions->value() eq 'readOnly') {
                push (@readOnly, $user);
            } elsif ($permissions->value() eq 'readWrite') {
                push (@readWrite, $user);
            } elsif ($permissions->value() eq 'administrator') {
                push (@administrators, $user)
            }
        }

        if (not $all) {
            next unless (@readOnly or @readWrite or @administrators
                         or $shareConf->{'guest'});
        }

        $shareConf->{'readOnly'} = join (', ', @readOnly);
        $shareConf->{'readWrite'} = join (', ', @readWrite);
        $shareConf->{'administrators'} = join (', ', @administrators);
        $shareConf->{'validUsers'} = join (', ', @readOnly,
                                                 @readWrite,
                                                 @administrators);
        push (@shares, $shareConf);
    }

    return \@shares;
}

# Method: provision
#
#   This method provision the database
#
sub provision
{
    my ($self) = @_;


    # This file must be deleted or provision may fail
    EBox::Sudo::root('rm -f ' . SAMBACONFFILE);
    my $cmd = SAMBAPROVISION .
        ' --domain=' . $self->workgroup() .
        ' --workgroup=' . $self->workgroup() .
        ' --realm=' . $self->realm() .
        ' --dns-backend=BIND9_FLATFILE' .
        ' --server-role=' . $self->mode() .
        ' --adminpass=' . $self->administratorPassword();
    EBox::debug("Provisioning database '$cmd'");
    try {
        my $output = EBox::Sudo::root($cmd);
        EBox::debug("Provision result: @{$output}");
    } otherwise {
        my $error = shift;
        throw EBox::Exceptions::Internal("Error provisioning database: $error");
    };
    EBox::Sudo::root('chown root:bind ' . SAMBADNSZONE);

    # Enable reversible encryption to sync passwords
    # NOTE complexity is disabled because when changing password in
    #      zentyal the command may fail if it do not meet requirements,
    #      ending with different passwords
    EBox::debug('Setting password policy');
    $cmd = SAMBATOOL . " domain passwordsettings set" .
                       " --store-plaintext=on " .
                       " --complexity=off "  .
                       " --min-pwd-length=0";
    EBox::Sudo::root($cmd);

    # Set the proper permissions to allow 'ebox' user read the ldb files
    my @cmds = ();
    push (@cmds, 'chown root:ebox /var/lib/samba/private/idmap.ldb');
    push (@cmds, 'chmod 660 /var/lib/samba/private/idmap.ldb');
    push (@cmds, 'chown root:ebox /var/lib/samba/private/sam.ldb.d');
    push (@cmds, 'chmod 670 /var/lib/samba/private/sam.ldb.d');
    push (@cmds, 'chown root:ebox /var/lib/samba/private/sam.ldb.d/*');
    push (@cmds, 'chmod 660 /var/lib/samba/private/sam.ldb.d/*');
    EBox::Sudo::root(@cmds);

    # Update the "Domain Users" xid mapping to the gid of __USERS__
    EBox::debug("Mapping 'Domain Users' group to __USERS__");
    my $users = EBox::Global->modInstance('users');
    my $dn = $users->groupDn(EBox::UsersAndGroups->DEFAULTGROUP);
    my $gid = new EBox::UsersAndGroups::Group(dn => $dn)->get('gidNumber');
    $self->ldb()->xidMapping('Domain Users', $gid);

    # Export all zentyal users and groups to ldb
    EBox::debug('Exporting LDAP to LDB');
    try {
        #$self->ldb()->ldapToLdb(); TODO
    } otherwise {
        my $error = shift;
        throw EBox::Exceptions::Internal("Error exporting LDAP to LDB: $error");
    };

    # Mark the module as provisioned
    EBox::debug('Setting provisioned flag');
    $self->set_bool('provisioned', 1);
}

#sub _exposedMethods
#{
#    return {
#            'getPathByShareName' => {
#            'action' => 'get',
#                'path' => [ 'SambaShares'],
#                'indexes' => [ 'share'],
#                'selector' => [ 'path']
#            },
#            'getUserByIndex' => {
#                'action' => 'get',
#                'path' => [ 'SambaShares',
#                'access'
#                    ],
#                'indexes' => ['share', 'id'],
#                'selector' => ['user_group']
#            },
#            'getPermissionsByIndex' => {
#                'action' => 'get',
#                'path' => [ 'SambaShares',
#                'access'
#                    ],
#                'indexes' => ['share', 'id'],
#                'selector' => ['permissions']
#            }
#    };
#}

# Return interfaces upon samba should listen
sub sambaInterfaces
{
    my ($self) = @_;
    my @ifaces;

    # Always listen on loopback interface
    push (@ifaces, 'lo');

    my $net = EBox::Global->modInstance('network');

    my $listen_external = EBox::Config::configkey('listen_external');

    my $netIfaces;
    if ($listen_external eq 'yes') {
        $netIfaces = $net->allIfaces();
    } else {
        $netIfaces = $net->InternalIfaces();
    }

    foreach my $iface (@{$netIfaces}) {
        push @ifaces, $iface;

        if ($net->ifaceMethod($iface) eq 'bridged') {
            my $br = $net->ifaceBridge($iface);
            push (@ifaces, "br$br");
            next;
        }

        my $vifacesNames = $net->vifaceNames($iface);
        if (defined $vifacesNames) {
            push @ifaces, @{$vifacesNames};
        }
    }

    my @moduleGeneratedIfaces = ();

    # XXX temporal fix until #529 is fixed
    #if ($global->modExists('openvpn')) {
    #    my $openvpn = $global->modInstance('openvpn');
    #    my @openvpnDaemons = $openvpn->activeDaemons();
    #    my @openvpnIfaces  = map { $_->iface() }  @openvpnDaemons;

    #    push @moduleGeneratedIfaces, @openvpnIfaces;
    #}

    push @ifaces, @moduleGeneratedIfaces;
    return \@ifaces;
}

sub _preSetConf
{
    my ($self) = @_;

    EBox::debug('stopping service');
    $self->_stopService();
}

sub _setConf
{
    my ($self) = @_;

    # TODO Check user_xattr in fstab and remount if necessary

    unless ($self->get_bool('provisioned')) {
        $self->provision();
    }

    my $interfaces = join (',', @{$self->sambaInterfaces()});

    my $prefix = EBox::Config::configkey('custom_prefix');
    $prefix = 'zentyal' unless $prefix;

    my @array = ();
    push(@array, 'prefix'      => $prefix);
    push(@array, 'ifaces'      => $interfaces);
    push(@array, 'mode'        => $self->mode());
    push(@array, 'workgroup'   => $self->workgroup());
    push(@array, 'realm'       => $self->realm());
    push(@array, 'netbiosName' => $self->netbiosName());
    push(@array, 'description' => $self->description());
    push(@array, 'drive'       => $self->drive());
    push(@array, 'roaming'     => $self->roamingProfiles());
    push(@array, 'backup_path' => EBox::Config::conf() . 'backups');
    push(@array, 'printers'    => $self->_sambaPrinterConf());
    push(@array, 'active_printer'  => $self->printerService());

    my $shares = $self->shares();
    push(@array, 'shares' => $shares);
    my $guestShares = 0;
    foreach my $share (@{$shares}) {
        if ($share->{'guest'}) {
            $guestShares = 1;
            last;
        }
    }
    push(@array, 'guest_shares' => $guestShares);

    my $netlogonDir = SAMBA_DIR , '/' . $self->realm() . '/scripts';
    if ($self->mode() eq 'dc') {
        my $logonScript = join('/', $netlogonDir, LOGON_SCRIPT);
        if (EBox::Sudo::fileTest('-f', $logonScript)) {
            push(@array, 'logon_script', LOGON_SCRIPT);
        }
        $self->writeConfFile(join('/', $netlogonDir, LOGON_DEFAULT_SCRIPT),
            'samba/logon.bat.mas', \@array);
    }

    $self->writeConfFile(SAMBACONFFILE,
                         'samba/smb.conf.mas', \@array);

    # Remove shares
    $self->model('SambaDeletedShares')->removeDirs();
    # Create samba shares
    $self->model('SambaShares')->createDirs();
}

sub _shareUsers
{
    my $state = 0;
    my $pids = {};

#    for my $line (`smbstatus`) {
#        chomp($line);
#        if($state == 0) {
#            if($line =~ '----------------------------') {
#                $state = 1;
#            }
#        } elsif($state == 1) {
#            if($line eq '') {
#                $state = 2;
#            } else {
#                # 1735  javi   javi     blackops  (192.168.45.48)
#                $line =~ m/(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\((\S+)\)/;
#                my ($pid, $user, $machine) = ($1, $2, $4);
#                $pids->{$pid} = { 'user' => $user, 'machine' => $machine };
#            }
#        } elsif($state == 2) {
#            if($line =~ '----------------------------') {
#                $state = 3;
#            }
#        } elsif($state == 3) {
#            if($line eq '') {
#                last;
#            } else {
#            #administracion   1735   blackops      Wed Nov 26 17:27:19 2008
#                $line =~ m/(\S+)\s+(\d+)\s+(\S+)\s+(\S.+)/;
#                my($share, $pid, $date) = ($1, $2, $4);
#                $pids->{$pid}->{'share'} = $share;
#                $pids->{$pid}->{'date'} = $date;
#            }
#        }
#    }
    return [values %{$pids}];
}

sub _sharesGroupedBy
{
    my ($group) = @_;

    my $shareUsers = _shareUsers();

    my $groupedInfo = {};
    foreach my $info (@{$shareUsers}) {
        if (not defined ($groupedInfo->{$info->{$group}})) {
            $groupedInfo->{$info->{$group}} = [];
        }
        push (@{$groupedInfo->{$info->{$group}}}, $info);
    }
    return $groupedInfo;
}

sub sharesByUserWidget
{
    my ($widget) = @_;

    my $sharesByUser = _sharesGroupedBy('user');

    foreach my $user (sort keys %{$sharesByUser}) {
        my $section = new EBox::Dashboard::Section($user, $user);
        $widget->add($section);
        my $titles = [__('Share'), __('Source machine'), __('Connected since')];

        my $rows = {};
        foreach my $share (@{$sharesByUser->{$user}}) {
            my $id = $share->{'share'} . '_' . $share->{'machine'};
            $rows->{$id} = [$share->{'share'}, $share->{'machine'}, $share->{'date'}];
        }
        my $ids = [sort keys %{$rows}];
        $section->add(new EBox::Dashboard::List(undef, $titles, $ids, $rows));
    }
}

sub usersByShareWidget
{
    my ($widget) = @_;

    my $usersByShare = _sharesGroupedBy('share');

    for my $share (sort keys %{$usersByShare}) {
        my $section = new EBox::Dashboard::Section($share, $share);
        $widget->add($section);
        my $titles = [__('User'), __('Source machine'), __('Connected since')];

        my $rows = {};
        foreach my $user (@{$usersByShare->{$share}}) {
            my $id = $user->{'user'} . '_' . $user->{'machine'};
            $rows->{$id} = [$user->{'user'}, $user->{'machine'}, $user->{'date'}];
        }
        my $ids = [sort keys %{$rows}];
        $section->add(new EBox::Dashboard::List(undef, $titles, $ids, $rows));
    }
}

# Method: widgets
#
#   Override EBox::Module::widgets
#
sub widgets
{
    return {
        'sharesbyuser' => {
            'title' => __('Shares by user'),
            'widget' => \&sharesByUserWidget,
            'order' => 7,
            'default' => 1
        },
        'usersbyshare' => {
            'title' => __('Users by share'),
            'widget' => \&usersByShareWidget,
            'order' => 9,
            'default' => 1
        }
    };
}

# Method: _daemons
#
#       Override EBox::Module::Service::_daemons
#
sub _daemons
{
    return [
        {
            'name' => 'samba4',
        },
    ];
}

# Function: usesPort
#
#       Implements EBox::FirewallObserver interface
#
sub usesPort # (protocol, port, iface)
{
    my ($self, $protocol, $port, $iface) = @_;

    return undef unless($self->isEnabled());

    foreach my $smbport (@{$PORTS}) {
        return 1 if ($port eq $smbport->{destinationPort});
    }

    return undef;
}

sub firewallHelper
{
    my ($self) = @_;

    if ($self->isEnabled()) {
        return new EBox::SambaFirewall();
    }
    return undef;
}

sub menu
{
    my ($self, $root) = @_;

    $root->add(new EBox::Menu::Item('url' => 'Samba/Composite/General',
                                    'text' => $self->printableName(),
                                    'separator' => 'Office',
                                    'order' => 540));
}

#   Function: setPrinterService
#
#       Sets the printer sharing service through samba and cups
#
#   Parameters:
#
#       enabled - boolean. True enable, undef disable
#
sub setPrinterService # (enabled)
{
    my ($self, $active) = @_;
    ($active and $self->printerService) and return;
    (not $active and not $self->printerService) and return;

    $self->set_bool('printer_active', $active);
}

#   Method: servicePrinter
#
#       Returns if the printer sharing service is enabled
#
#   Returns:
#
#       boolean - true if enabled, otherwise undef
#
sub printerService
{
    my ($self) = @_;

    return $self->get_bool('printer_active');
}

# Method: defaultAdministratorPassword
#
#   Generates a default administrator password
#
sub defaultAdministratorPassword
{
    return 'Zentyal1234';
}

# Method: administratorPassword
#
#   Returns the administrator password
sub administratorPassword
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->passwordValue();
}

# Method: defaultNetbios
#
#   Generates the default netbios server name
#
sub defaultNetbios
{
    my $hostname = Sys::Hostname::hostname();
    return $hostname;
}

# Method: netbiosName
#
#   Returns the configured netbios name
#
sub netbiosName
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->netbiosNameValue();
}

# Method: defaultRealm
#
#   Generates the default realm
#
sub defaultRealm
{
    my $prefix = EBox::Config::configkey('custom_prefix');
    $prefix = 'zentyal' unless $prefix;

    my $domain = Net::Domain::hostdomain();
    $domain = "$prefix.domain" unless $domain;

    return $domain;
}

# Method: realm
#
#   Returns the configured realm
#
sub realm
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->realmValue();
}

# Method: defaultWorkgroup
#
#   Generates the default workgroup
#
sub defaultWorkgroup
{
    my $prefix = EBox::Config::configkey('custom_prefix');
    $prefix = 'zentyal' unless $prefix;

    return uc($prefix) . '-DOMAIN';
}

# Method: workgroup
#
#   Returns the configured workgroup name
#
sub workgroup
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->workgroupValue();
}

# Method: defaultDescription
#
#   Generates the default server string
#
sub defaultDescription
{
    my $prefix = EBox::Config::configkey('custom_prefix');
    $prefix = 'zentyal' unless $prefix;

    return ucfirst($prefix) . ' File Server';
}

# Method: description
#
#   Returns the configured description string
#
sub description
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->descriptionValue();
}

# Method: roamingProfiles
#
#   Returns if roaming profiles are enabled
#
sub roamingProfiles
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->roamingValue();
}

# Method: mode
#
#   Returns the configured server mode
#
sub mode
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->modeValue();
}

# Method: drive
#
#   Returns the configured drive letter
#
sub drive
{
    my ($self) = @_;

    my $model = $self->model('GeneralSettings');
    return $model->driveValue();
}

# Method: _ldapModImplementation
#
#   LdapModule implmentation
#
sub _ldapModImplementation
{
    my $self;

    return new EBox::SambaLdapUser();
}

sub _addPrinter
{
    my ($self, $name) = @_;

    $self->set_list("printers/$name/users", 'string', []);
    $self->set_list("printers/$name/groups", 'string', []);
    $self->set_bool("printers/$name/external", 1);
}

sub printers
{
    my ($self) = @_;

    my $global = EBox::Global->getInstance();
    my %external;
    if ($global->modExists('printers')) {
        my $printers = $global->modInstance('printers');
        %external = map { $_ => 'new' } @{$printers->fetchExternalCUPSPrinters()};
    } else {
        return [];
    }

    my @printers;
    my $readOnly = $self->isReadOnly();
    foreach my $printer (@{$self->array_from_dir('printers')}) {
        my $name = $printer->{'_dir'};
        if (exists $external{$name}) {
            $external{$name} = 'exists';
        } else {
            $self->delPrinter($name) unless ($readOnly);
            $external{$name} = 'removed';
        }
        push (@printers,  $printer->{'_dir'});
    }

    unless ($readOnly) {
        foreach my $newPrinter (grep { $external{$_} eq 'new' } keys %external) {
            $self->_addPrinter($newPrinter);
            push (@printers, $newPrinter);
        }
    }

    return [sort @printers];
}

sub ignorePrinterNotFound
{
    my ($self) = @_;

    return $self->get_bool('ignorePrinterNotFound');
}

sub _printerNotFound
{
    my ($self, $printer) = @_;

    unless ($self->ignorePrinterNotFound()) {
        throw EBox::Exceptions::DataNotFound('data' => 'printer',
                'value' => $printer);
    }
}

sub _setPrinterUsers
{
    my ($self, $printer, $users) = @_;

    unless ($self->dir_exists("printers/$printer")) {
        $self->_printerNotFound($printer);
        return;
    }

    my $usermod = EBox::Global->modInstance('users');
    my @okUsers = grep {
        $usermod->userExists($_)
    } @{ $users };

    $self->set_list("printers/$printer/users", "string", \@okUsers);
}

sub _setPrinterGroups
{
    my ($self, $printer, $groups) = @_;

    unless ($self->dir_exists("printers/$printer")) {
        $self->_printerNotFound($printer);
        return;
    }

    my $groupmod = EBox::Global->modInstance('users');
    my @okGroups = grep {
        $groupmod->groupExists($_)
    } @{ $groups };

    $self->set_list("printers/$printer/groups", "string", \@okGroups);
}

sub _printerUsers # (printer)
{
    my ($self, $printer) = @_;

    unless ($self->dir_exists("printers/$printer")) {
        $self->_printerNotFound($printer);
        return [];
    }

    return $self->get_list("printers/$printer/users");
}

sub _printerGroups # (group)
{
    my ($self, $printer) = @_;

    unless ($self->dir_exists("printers/$printer")) {
        $self->_printerNotFound($printer);
        return [];
    }

    return $self->get_list("printers/$printer/groups");
}

sub _printersForUser # (user)
{
    my ($self, $user) = @_;

    my @printers;
    for my $name (@{$self->printers()}) {
        my $print = { 'name' => $name, 'allowed' => undef };
        my $users = $self->get_list("printers/$name/users");
        if (@{$users}) {
            $print->{'allowed'} = 1 if (grep(/^$user$/, @{$users}));
        }
        push (@printers, $print);
    }

    return \@printers;
}

sub setPrintersForUser
{
    my ($self, $user, $newconf) = @_;

    $self->_checkUserExists($user);

    my %newConf = map {
        $_->{name} => $_->{allowed}
    } @{$newconf};

    my @printers = @{$self->printers()};
    foreach my $printer (@printers) {
        my @printerUsers = @{$self->_printerUsers($printer)};
        my $userAllowed = grep { $user eq $_ } @printerUsers;
        my $allowed = exists $newConf{$printer} ? $newConf{$printer} : 0;
        if ($allowed and (not $userAllowed)) {
            push @printerUsers, $user;
            $self->_setPrinterUsers($printer, \@printerUsers)
        } elsif (not $allowed and $userAllowed) {
            @printerUsers = grep { $user ne $_ } @printerUsers;
            $self->_setPrinterUsers($printer, \@printerUsers)
        }
    }
}

sub _printersForGroup # (group)
{
    my ($self, $group) = @_;

    $self->_checkGroupExists($group);

    my @printers;
    for my $name (@{$self->printers()}) {
        my $print = { 'name' => $name, 'allowed' => undef };
        my $groups = $self->get_list("printers/$name/groups");
        if (@{$groups}) {
            $print->{'allowed'} = 1 if (grep(/^$group$/, @{$groups}));
        }
        push (@printers, $print);
    }

    return \@printers;
}

sub setPrintersForGroup
{
    my ($self, $group, $newconf) = @_;

    $self->_checkGroupExists($group);

    my %newConf = map {
        $_->{name} => $_->{allowed}
    } @{ $newconf };

    my @printers = @{ $self->printers() };
    foreach my $printer (@printers) {
        my @printerGroups = @{$self->_printerGroups($printer)};
        my $groupAllowed = grep { $group eq $_ } @printerGroups;
        my $allowed = exists $newConf{$printer} ? $newConf{$printer} : 0;
        if ($allowed and (not $groupAllowed)) {
            push @printerGroups, $group;
            $self->_setPrinterGroups($printer, \@printerGroups)
        } elsif (not $allowed and $groupAllowed) {
            @printerGroups = grep { $group ne $_ } @printerGroups;
            $self->_setPrinterGroups($printer, \@printerGroups)
        }
    }
}

sub delPrinter # (resource)
{
    my ($self, $name) = @_;

    unless ($self->dir_exists("printers/$name")) {
        throw EBox::Exceptions::DataNotFound(
            'data' => 'printer',
            'value' => $name);
    }

    $self->delete_dir("printers/$name");
}

#sub existsShareResource # (resource)
#{
#    my ($self, $name) = @_;
#
#    my $usermod = EBox::Global->modInstance('users');
#    if ($usermod->configured()) {
#        if ($usermod->userExists($name)) {
#            return __('user');
#        }
#
#        if ($usermod->groupExists($name)) {
#            return __('group');
#        }
#    }
#
#    for my $printer (@{$self->printers()}) {
#        return __('printer') if ($name eq $printer);
#    }
#
#    return undef;
#}

sub _checkUserExists # (user)
{
    my ($self, $user) = @_;

    my $usermod = EBox::Global->modInstance('users');
    unless ($usermod->userExists($user)){
        throw EBox::Exceptions::DataNotFound(
                'data'  => __('user'),
                'value' => $user);
    }

    return 1;
}

sub _checkGroupExists # (group)
{
    my ($self, $group) = @_;

    my $groupmod = EBox::Global->modInstance('users');
    unless ($groupmod->groupExists($group)){
        throw EBox::Exceptions::DataNotFound(
                'data'  => __('group'),
                'value' => $group);
    }

    return 1;
}

sub _sambaPrinterConf
{
    my ($self) = @_;

    my @printers;
    foreach my $printer (@{$self->printers()}) {
        my $users = "";
        for my $user (@{$self->_printerUsers($printer)}) {
            $users .= "\"$user\" ";
        }
        for my $group (@{$self->_printerGroups($printer)}) {
            $users .= "\@\"$group\" ";
        }
        push (@printers, { 'name' => $printer , 'users' => $users});
    }

    return \@printers;
}


sub restoreConfig
{
    my ($self, $dir) = @_;

    $self->set_bool('ignorePrinterNotFound', 1);

#    try {
#       TODO: Provision database and export LDAP to LDB
#        my $sambaLdapUser = new EBox::SambaLdapUser;
#        $sambaLdapUser->migrateUsers();
#    } finally {
        $self->set_bool('ignorePrinterNotFound', 0);
#    }
}

sub restoreDependencies
{
    my @depends = ();

    push (@depends, 'users');

    if (EBox::Global->modExists('printers')) {
        push (@depends, 'printers');
    }

    return \@depends;
}


# backup domains

#sub backupDomains
#{
#    my $name = 'shares';
#    my %attrs  = (
#                  printableName => __('File Sharing'),
#                  description   => __(q{Shares, users and groups homes and profiles}),
#                 );
#
#    return ($name, \%attrs);
#}

#sub backupDomainsFileSelection
#{
#    my ($self, %enabled) = @_;
#    if ($enabled{shares}) {
#        my $sambaLdapUser = new EBox::SambaLdapUser();
#        my @dirs = @{ $sambaLdapUser->sharedDirectories() };
#        push @dirs, map {
#            $_->{path}
#        } @{ $self->shares(1) };
#
#        my $selection = {
#                          includes => \@dirs,
#                         };
#        return $selection;
#    }
#
#    return {};
#}

# Overrides:
#   EBox::Report::DiskUsageProvider::_facilitiesForDiskUsage
#sub _facilitiesForDiskUsage
#{
#    my ($self) = @_;
#
#    my $usersPrintableName  = __(q{Users files});
#    my $usersPath           = EBox::SambaLdapUser::usersPath();
#    my $groupsPrintableName = __(q{Groups files});
#    my $groupsPath          = EBox::SambaLdapUser::groupsPath();
#
#    return {
#        $usersPrintableName   => [ $usersPath ],
#        $groupsPrintableName  => [ $groupsPath ],
#    };
#}

# Implement LogHelper interface
#sub tableInfo
#{
#    my ($self) = @_;
#
#    my $access_titles = {
#        'timestamp' => __('Date'),
#        'client' => __('Client address'),
#        'username' => __('User'),
#        'event' => __('Action'),
#        'resource' => __('Resource'),
#    };
#    my @access_order = qw(timestamp client username event resource);;
#    my $access_events = {
#        'connect' => __('Connect'),
#        'opendir' => __('Access to directory'),
#        'readfile' => __('Read file'),
#        'writefile' => __('Write file'),
#        'disconnect' => __('Disconnect'),
#        'unlink' => __('Remove'),
#        'mkdir' => __('Create directory'),
#        'rmdir' => __('Remove directory'),
#        'rename' => __('Rename'),
#    };
#
#    my $virus_titles = {
#        'timestamp' => __('Date'),
#        'client' => __('Client address'),
#        'filename' => __('File name'),
#        'virus' => __('Virus'),
#        'event' => __('Type'),
#    };
#    my @virus_order = qw(timestamp client filename virus event);;
#    my $virus_events = { 'virus' => __('Virus') };
#
#    my $quarantine_titles = {
#        'timestamp' => __('Date'),
#        'filename' => __('File name'),
#        'qfilename' => __('Quarantined file name'),
#        'event' => __('Quarantine'),
#    };
#    my @quarantine_order = qw(timestamp filename qfilename event);
#    my $quarantine_events = { 'quarantine' => __('Quarantine') };
#
#    return [{
#        'name' => __('Samba access'),
#        'tablename' => 'samba_access',
#        'titles' => $access_titles,
#        'order' => \@access_order,
#        'timecol' => 'timestamp',
#        'filter' => ['client', 'username', 'resource'],
#        'types' => { 'client' => 'IPAddr' },
#        'events' => $access_events,
#        'eventcol' => 'event'
#    },
#    {
#        'name' => __('Samba virus'),
#        'tablename' => 'samba_virus',
#        'titles' => $virus_titles,
#        'order' => \@virus_order,
#        'timecol' => 'timestamp',
#        'filter' => ['client', 'filename', 'virus'],
#        'types' => { 'client' => 'IPAddr' },
#        'events' => $virus_events,
#        'eventcol' => 'event'
#    },
#    {
#        'name' => __('Samba quarantine'),
#        'tablename' => 'samba_quarantine',
#        'titles' => $quarantine_titles,
#        'order' => \@quarantine_order,
#        'timecol' => 'timestamp',
#        'filter' => ['filename'],
#        'events' => $quarantine_events,
#        'eventcol' => 'event'
#    }];
#}
#
#sub logHelper
#{
#    my ($self) = @_;
#
#    return (new EBox::SambaLogHelper);
#}
#
#sub isAntivirusPresent
#{
#
#    my $global = EBox::Global->getInstance();
#
#    return ($global->modExists('antivirus')
#             and (-f '/usr/lib/samba/vfs/vscan-clamav.so'));
#}
#
#sub report
#{
#    my ($self, $beg, $end, $options) = @_;
#    my $maxTopActivityUsers = $options->{'max_top_activity_users'};
#    my $maxTopActivityGroups = $options->{'max_top_activity_groups'};
#    my $maxTopSizeShares = $options->{'max_top_size_shares'};
#    my $maxTopVirusShares = $options->{'max_top_virus_shares'};
#
#    my $report = {};
#
#    $report->{'activity'} = $self->runMonthlyQuery($beg, $end, {
#        'select' => 'COALESCE(SUM(operations), 0) AS OPERATIONS',
#        'from' => 'samba_access_report'
#    });
#
#    $report->{'top_activity_users'} = $self->runQuery($beg, $end, {
#        'select' => 'username, SUM(operations) AS operations',
#        'from' => 'samba_access_report',
#        'group' => 'username',
#        'limit' => $maxTopActivityUsers,
#        'order' => 'operations DESC'
#    });
#
#
#    $report->{top_activity_groups} = _topActivityGroups($self, $beg, $end, $maxTopActivityGroups);
#
#    $report->{'top_size_shares'} = $self->runQuery($beg, $end, {
#        'select' => 'share, type, AVG(size) AS size',
#        'from' => 'samba_disk_usage_report',
#        'group' => 'share, type',
#        'limit' => $maxTopSizeShares,
#        'order' => 'size DESC',
#    });
#
#    $report->{'top_size_user_shares'} = $self->runQuery($beg, $end, {
#        'select' => 'share, AVG(size) AS size',
#        'from' => 'samba_disk_usage_report',
#        'group' => 'share',
#        'limit' => $maxTopSizeShares,
#        'order' => 'size DESC',
#        'where' => q{type = 'user'}
#    });
#
#    $report->{'top_size_group_shares'} = $self->runQuery($beg, $end, {
#        'select' => 'share, AVG(size) AS size',
#        'from' => 'samba_disk_usage_report',
#        'group' => 'share, type',
#        'limit' => $maxTopSizeShares,
#        'order' => 'size DESC',
#        'where' => q{type = 'group'}
#    });
#
#    $report->{'top_size_custom_shares'} = $self->runQuery($beg, $end, {
#        'select' => 'share, AVG(size) AS size',
#        'from' => 'samba_disk_usage_report',
#        'group' => 'share, type',
#        'limit' => $maxTopSizeShares,
#        'order' => 'size DESC',
#        'where' => q{type = 'custom'}
#    });
#
#    $report->{'top_virus_shares'} = $self->runQuery($beg, $end, {
#        'select' => 'share, SUM(virus) as virus',
#        'from' => 'samba_virus_share_report',
#        'group' => 'share',
#        'limit' => $maxTopVirusShares,
#        'order' => 'virus DESC',
#    });
#
#
#    return $report;
#}
#
#sub _topActivityGroups
#{
#    my ($self, $beg, $end, $maxTopActivityGroups) = @_;
#    my $usersMod = EBox::Global->modInstance('users');
#
#    my $sqlResult = $self->runQuery($beg, $end, {
#        'select' => 'username, SUM(operations) AS operations',
#        'from' => 'samba_access_report',
#        'group' => 'username',
#    });
#    my %operationsByUser;
#    foreach my $i (0 .. $#{ $sqlResult->{username} } ) {
#        $operationsByUser{ $sqlResult->{username}->[$i] } =  $sqlResult->{operations}->[$i];
#    }
#
#    delete $sqlResult->{username};
#    delete $sqlResult->{operations};
#
#
#    my $min = -1;
#    my @groupsAndOperations;
#    foreach my $group_r ($usersMod->groups()) {
#        my $groupname = $group_r->{account};
#        my $operations = 0;
#
#        my @users = @{ $usersMod->usersInGroup($groupname) };
#        foreach my $user (@users) {
#            $operations += $operationsByUser{$user};
#        }
#
#
#        if (@groupsAndOperations <   $maxTopActivityGroups ) {
#            push @groupsAndOperations, [$groupname => $operations];
#        } elsif ($operations > $min) {
#            pop @groupsAndOperations;
#            push @groupsAndOperations, [$groupname => $operations];
#        } else {
#            next;
#        }
#
#        @groupsAndOperations = sort { $b->[1] <=> $a->[1]  } @groupsAndOperations;
#        $min = $groupsAndOperations[-1]->[1];
#    }
#
#    my @topGroups     = map { $_->[0]  } @groupsAndOperations;
#    my @topOperations = map { $_->[1] } @groupsAndOperations;
#    return {
#            'groupname' => \@topGroups,
#            'operations' => \@topOperations,
#           };
#}
#
#sub consolidateReportQueries
#{
#    return [
#        {
#            'target_table' => 'samba_access_report',
#            'query' => {
#                'select' => 'username, COUNT(event) AS operations',
#                'from' => 'samba_access',
#                'group' => 'username'
#            },
#            quote => { username => 1 },
#        },
#        {
#            'target_table' => 'samba_virus_report',
#            'query' => {
#                'select' => 'client, COUNT(event) AS virus',
#                'from' => 'samba_virus',
#                'group' => 'client'
#            },
#            quote => { client => 1 },
#        },
#        {
#            'target_table' => 'samba_disk_usage_report',
#            'query' => {
#                'select' => 'share, type, CAST (AVG(size) AS int) AS size',
#                'from' => 'samba_disk_usage',
#                'group' => 'share, type'
#
#            },
#            quote => { share => 1 },
#        },
#        {
#            'target_table' => 'samba_virus_share_report',
#            'query' => {
#                'select' => 'share, count(*) as virus',
#                'from' => 'samba_quarantine',
#                'where' => q{event='quarantine'},
#                'group' => 'filename'
#            },
#            'rowConversor' => \&_virusShareReportRowConversor,
#            'targetGroupFields' => ['share'],
#            quote => { share => 1 },
#        },
#    ];
#}
#
#my @sharesSortedByPathLen;
#
#sub _updatePathsByLen
#{
#    my ($self) = @_;
#
#    my $ldapInfo = EBox::SambaLdapUser->new();
#    @sharesSortedByPathLen = map {
#         { path => $_->{path},
#           share => $_->{sharename} }
#    } ( @{ $ldapInfo->userShareDirectories },
#        @{ $ldapInfo->groupShareDirectories }
#      );
#
#    foreach my $sh_r (@{ $self->shares(1) }) {
#        push @sharesSortedByPathLen, {path => $sh_r->{path},
#                                      share =>  $sh_r->{share} };
#    }
#
#    # add regexes
#    foreach my $share (@sharesSortedByPathLen) {
#        my $path = $share->{path};
#        $share->{pathRegex} = qr{^$path/};
#    }
#
#    @sharesSortedByPathLen = sort {
#        length($b->{path}) <=>  length($a->{path})
#    } @sharesSortedByPathLen;
#}
#
#sub _shareByFilename
#{
#    my ($filename) = @_;
#
#    if (not @sharesSortedByPathLen) {
#        my $samba =EBox::Global->modInstance('samba');
#        $samba->_updatePathsByLen();
#    }
#
#
#    foreach my $shareAndPath (@sharesSortedByPathLen) {
#        if ($filename =~ m/$shareAndPath->{pathRegex}/) {
#            return $shareAndPath->{share};
#        }
#    }
#
#
#    return undef;
#}
#
#sub _virusShareReportRowConversor
#{
#    my ($row) = @_;
#    my $filename = delete $row->{filename};
#    my $share = _shareByFilename($filename);
#    EBox::debug("COBV $filename -> $share");
#    if ($share) {
#        $row->{share} = $share;
#    } else {
#        return undef;
#    }
#
#
#    return $row;
#}
#
#sub logReportInfo
#{
#    my ($self) = @_;
#
#    if ($self->_diskUsageAlreadyCheckedToday) {
#        return [];
#    }
#
#    my @reportData;
#
#    my %shareByPath;
#
#    my @shares = @{ $self->_sharesAndSizes() };
#
#
#    foreach my $share (@shares) {
#        # add info about disk usage by share
#        my $entry = {
#                     table => 'samba_disk_usage',
#                     values => {
#                                share => $share->{share},
#                                size  => $share->{size},
#                                type  => $share->{type},
#                               }
#                    };
#        push @reportData, $entry;
#    }
#
#    return \@reportData;
#}
#
#sub _diskUsageAlreadyCheckedToday
#{
#    my ($self) = @_;
#
#    my $db = EBox::DBEngineFactory::DBEngine();
#    my $query = q{SELECT share FROM samba_disk_usage WHERE (timestamp >= (current_date + interval '0 day')) AND (timestamp < (current_date + interval '1 day'))};
#    my $results = $db->query($query);
#    return @{ $results } > 0;
#}
#
#sub _sharesAndSizes
#{
#    my ($self) = @_;
#
#    my $ldapInfo = EBox::SambaLdapUser->new();
#    my @shares;
#
#    foreach my $sh_r ( @{ $ldapInfo->userShareDirectories }) {
#        my $share = {
#                     share => $sh_r->{sharename},
#                     path  => $sh_r->{path},
#                     type  => 'user',
#                    };
#        push @shares, $share;
#    }
#
#    foreach my $sh_r ( @{ $ldapInfo->groupShareDirectories }) {
#        my $share = {
#                     share => $sh_r->{sharename},
#                     path  => $sh_r->{path},
#                     type  => 'group',
#                    };
#        push @shares, $share;
#    }
#
#    # add no-account shares to share list
#    foreach my $sh_r (@{ $self->shares(1)  }) {
#        my $share = {
#                     share => $sh_r->{share},
#                     path  => $sh_r->{path},
#                     type  => 'custom',
#                    };
#        push @shares, $share;
#    }
#
#
#    foreach my $share (@shares) {
#        my $path = $share->{path};
#        if (EBox::Sudo::fileTest('-d', $path)) {
#            my $output = EBox::Sudo::rootWithoutException("du -ms '$path'");
#
#            my ($size) =  $output->[0] =~ m{^(\d+)};
#            if (not defined $size) {
#                EBox::error("Problem getting $path size: @{$output}");
#                $size = 0;
#            }
#
#            $share->{size} = $size;
#        }
#    }
#
#    return \@shares;
#}

# Method: ldb
#
#   Provides an EBox::Ldb object with the proper settings
#
sub ldb
{
    my ($self) = @_;

    unless(defined($self->{ldb})) {
        $self->{ldb} = EBox::Ldb->new();
    }
    return $self->{ldb};
}

1;
