package FusionInventory::Agent::Task::Inventory::Win32::Registry;

use strict;
use warnings;

use English qw(-no_match_vars);

use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Win32;


my @hives = qw/
    HKEY_CLASSES_ROOT
    HKEY_CURRENT_USER
    HKEY_LOCAL_MACHINE
    HKEY_USERS
    HKEY_CURRENT_CONFIG
    HKEY_DYN_DATA
/;

sub isEnabled {
    my (%params) = @_;

    return $params{registry};
}

sub _getRegistryData {
    my (%params) = @_;

    my @data;

    my @registrys = ref($params{registry}->{PARAM}) eq 'ARRAY' ?
         @{$params{registry}->{PARAM}} :
         ($params{registry}->{PARAM});

    foreach my $option (@registrys) {

        my $name = $option->{NAME};
        my $regkey = $option->{REGKEY};
        my $regtree = $option->{REGTREE};
        my $content = $option->{content};

        # This should never append, err wait...
        next unless $content;

        $regkey =~ s{\\}{/}g;
        my $value = getRegistryValues(
            path   => $hives[$regtree]."/".$regkey."/".$content,
            logger => $params{logger}
        );

        return unless ref($value) eq "HASH";

        if (keys %$value >  1) { # compat with OCS odd data structur
            foreach ( keys %$value ) {
                my $n = encodeFromRegistry($_) || '';
                my $v = encodeFromRegistry($value->{$_}) || '';
                push @data, { section => 'REGISTRY', entry => {
                        NAME => $name,
                        REGVALUE => "$n=$v"
                    }
                };
            }
        } else {
# TODO: broken in 2.3.x
            push @data, {section => 'REGISTRY', entry => {
                    NAME => $name, 
                    REGVALUE => encodeFromRegistry($value->{name})
                }
            };
        }
    }


    return @data;
}

sub doInventory {
    my (%params) = @_;

    return unless $params{registry}->{NAME} eq 'REGISTRY';

    foreach my $data (_getRegistryData(
                registry => $params{registry},
                logger => $params{logger}))
    {
        $params{inventory}->addEntry(%$data);
    }


}

1;
