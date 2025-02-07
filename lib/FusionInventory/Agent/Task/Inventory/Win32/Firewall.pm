package FusionInventory::Agent::Task::Inventory::Win32::Firewall;

use strict;
use warnings;

use parent 'FusionInventory::Agent::Task::Inventory::Module';

use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Win32;
use FusionInventory::Agent::Tools::Constants;

use Storable 'dclone';

my @mappingFirewallProfiles = qw/public standard domain/;

sub isEnabled {
    my (%params) = @_;
    return 0 if $params{no_category}->{firewall};
    return 1;
}

sub isEnabledForRemote {
    my (%params) = @_;
    return 0 if $params{no_category}->{firewall};
    return 1;
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};

    for my $profile (_makeProfileAndConnectionsAssociation()) {
        $inventory->addEntry(
            section => 'FIREWALL',
            entry   => $profile
        );
    }
}

sub _getFirewallProfiles {
    my (%params) = @_;

    my $key = $params{key} || getRegistryKey(
        path => "HKEY_LOCAL_MACHINE/SYSTEM/CurrentControlSet/services/SharedAccess/Parameters/FirewallPolicy",
        wmiopts => { # Only used for remote WMI optimization
            values  => [ qw/EnableFirewall/ ]
        }
    );

    return unless $key;

    my $subKeys = {
        domain   => 'DomainProfile',
        public   => 'PublicProfile',
        standard => 'StandardProfile'
    };
    my $profiles = {};
    for my $profile (keys %$subKeys) {
        next unless $key->{$subKeys->{$profile} . '/'};
        next unless defined $key->{$subKeys->{$profile} . '/'}->{'/EnableFirewall'};
        my $enabled = hex2dec($key->{ $subKeys->{$profile} . '/'}->{'/EnableFirewall'});
        $profiles->{$profile} = {
            STATUS => $enabled
                ? STATUS_ON
                : STATUS_OFF,
            PROFILE => $subKeys->{$profile}
        };
    }

    return $profiles;
}

sub _makeProfileAndConnectionsAssociation {
    my (%params) = @_;

    my $firewallProfiles = _getFirewallProfiles()
        or return;

    my $profilesKey = $params{profilesKey} || getRegistryKey(
        path => 'HKEY_LOCAL_MACHINE/SOFTWARE/Microsoft/Windows NT/CurrentVersion/NetworkList/Profiles',
        wmiopts => { # Only used for remote WMI optimization
            values  => [ qw/ProfileName Category/ ]
        }
    );

    return unless $profilesKey;

    my $signaturesKey = $params{signaturesKey} || getRegistryKey(
        path => 'HKEY_LOCAL_MACHINE/SOFTWARE/Microsoft/Windows NT/CurrentVersion/NetworkList/Signatures',
        wmiopts => { # Only used for remote WMI optimization
            values  => [ qw/ProfileGuid FirstNetwork/ ]
        }
    );

    return unless $signaturesKey;

    my $DNSRegisteredAdapters = getRegistryKey(
        path => 'HKEY_LOCAL_MACHINE/SYSTEM/CurrentControlSet/services/Tcpip/Parameters/DNSRegisteredAdapters',
        wmiopts => { # Only used for remote WMI optimization
            values  => [ qw/PrimaryDomainName/ ]
        }
    );

    return unless $DNSRegisteredAdapters;

    foreach my $interface (getInterfaces()) {
        next if ($interface->{STATUS} ne 'Up') || !defined($interface->{GUID});

        my $profile;
        my $domainSettings = defined($interface->{GUID}) ? $DNSRegisteredAdapters->{$interface->{GUID}.'/'} : undef;
        # check if connection with domain
        if ($domainSettings) {
            $profile = _retrieveFirewallProfileWithdomain(
                profileName => $domainSettings->{'/PrimaryDomainName'},
                profilesKey => $profilesKey
            );
        } else {
            $profile = _retrieveFirewallProfileWithoutDomain(
                DNSDomain => $interface->{DNSDomain},
                profilesKey => $profilesKey,
                signaturesKey => $signaturesKey
            );
        }

        next unless $profile;

        my $category = hex2dec($profile->{'/Category'});
        unless (defined $firewallProfiles->{$mappingFirewallProfiles[$category]}->{CONNECTIONS}) {
            $firewallProfiles->{$mappingFirewallProfiles[$category]}->{CONNECTIONS} = [];
        }
        my $connection = {DESCRIPTION => $interface->{DESCRIPTION}};
        $connection->{IPADDRESS} = $interface->{IPADDRESS} if ($interface->{IPADDRESS});
        $connection->{IPADDRESS6} = $interface->{IPADDRESS6} if ($interface->{IPADDRESS6});
        push @{$firewallProfiles->{$mappingFirewallProfiles[$category]}->{CONNECTIONS}}, $connection;
    }

    my @profiles = ();
    for my $p (values %{$firewallProfiles}) {
        my @p;
        if ($p->{CONNECTIONS} && ref($p->{CONNECTIONS}) eq 'ARRAY') {
            my @conns = @{$p->{CONNECTIONS}};
            delete $p->{CONNECTIONS};
            for my $conn (@conns) {
                my $newP = dclone $p;
                while (my ($k, $v) = each %$conn) {
                    $newP->{$k} = $v;
                }
                push @p, $newP;
            }
        } else {
            push @p, $p;
        }
        push @profiles, @p;
    }

    return @profiles;
}

sub _retrieveFirewallProfileWithoutDomain {
    my (%params) = @_;

    return unless $params{DNSDomain} && $params{profilesKey} && $params{signaturesKey};

    my $profilesKey = $params{profilesKey};
    my $signaturesKey = $params{signaturesKey};

    my $dnsDomain = $params{DNSDomain};
    my $profileGuid;
    for my $sig (values %{$signaturesKey->{'Managed/'}}, values %{$signaturesKey->{'Unmanaged/'}}) {
        if ($sig->{'/FirstNetwork'} eq $dnsDomain) {
            $profileGuid = $sig->{'/ProfileGuid'};
            last;
        }
    }
    return unless $profileGuid && $profilesKey->{$profileGuid . '/'};

    return $profilesKey->{$profileGuid . '/'};
}

sub _retrieveFirewallProfileWithdomain {
    my (%params) = @_;

    return unless $params{profileName} && $params{profilesKey};

    my $profiles = $params{profilesKey};
    my $profile;
    for my $p (values %$profiles) {
        if ($p->{'/ProfileName'} && $p->{'/ProfileName'} eq $params{profileName}) {
            $profile = $p;
            last;
        }
    }

    return $profile;
}

1;
