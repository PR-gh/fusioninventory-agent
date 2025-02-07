package FusionInventory::Agent::Task::NetDiscovery;

use strict;
use warnings;
use threads;
use parent 'FusionInventory::Agent::Task';

use constant DEVICE_PER_MESSAGE => 4;

use English qw(-no_match_vars);
use Net::IP;
use Time::localtime;
use Time::HiRes qw(usleep);
use Thread::Queue v2.01;
use UNIVERSAL::require;

use FusionInventory::Agent::Version;
use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Network;
use FusionInventory::Agent::Tools::Hardware;
use FusionInventory::Agent::Tools::Expiration;
use FusionInventory::Agent::Tools::SNMP;
use FusionInventory::Agent::XML::Query;

use FusionInventory::Agent::Task::NetDiscovery::Version;
use FusionInventory::Agent::Task::NetDiscovery::Job;

our $VERSION = FusionInventory::Agent::Task::NetDiscovery::Version::VERSION;

sub isEnabled {
    my ($self, $response) = @_;

    if (!$self->{target}->isType('server')) {
        $self->{logger}->debug("NetDiscovery task not compatible with local target");
        return;
    }

    my @options = $response->getOptionsInfoByName('NETDISCOVERY');
    if (!@options) {
        $self->{logger}->debug("NetDiscovery task execution not requested");
        return;
    }

    my @jobs;
    foreach my $option (@options) {
        if (!$option->{RANGEIP}) {
            $self->{logger}->error("invalid job: no IP range defined");
            next;
        }

        my @ranges;
        foreach my $range (@{$option->{RANGEIP}}) {
            if (!$range->{IPSTART}) {
                $self->{logger}->error(
                    "invalid range: no first address defined"
                );
                next;
            }
            if (!$range->{IPEND}) {
                $self->{logger}->error(
                    "invalid range: no last address defined"
                );
                next;
            }
            push @ranges, $range;
        }

        if (!@ranges) {
            $self->{logger}->error("invalid job: no valid IP range defined");
            next;
        }

        my $params = $option->{PARAM}->[0];
        if (!$params) {
            $self->{logger}->error("invalid job: no PARAM defined");
            next;
        }
        if (!defined($params->{PID})) {
            $self->{logger}->error("invalid job: no PID defined");
            next;
        }

        push @jobs, FusionInventory::Agent::Task::NetDiscovery::Job->new(
            logger      => $self->{logger},
            params      => $params,
            credentials => $option->{AUTHENTICATION},
            ranges      => \@ranges,
        );
    }

    if (!@jobs) {
        $self->{logger}->error("no valid job found, aborting");
        return;
    }

    $self->{jobs} = \@jobs;

    return 1;
}

sub _discovery_thread {
    my ($self, $jobs, $done) = @_;

    my $count = 0;

    my $id = threads->tid();
    $self->{logger}->debug("[thread $id] creation");

    # run as long as they are a job to process
    while (my $job = $jobs->dequeue()) {

        last unless ref($job) eq 'HASH';
        last if $job->{leave};

        my $result = $self->_scanAddress($job);

        if ($result && defined($job->{entity})) {
            $result->{ENTITY} = $job->{entity};
        }

        # Only send result if a device was found which involves setting IP
        $self->_sendResultMessage($result, $job->{pid})
            if $result->{IP};

        $done->enqueue($job);
        $count ++;
    }

    delete $self->{logger}->{prefix};

    $self->{logger}->debug2("[thread $id] processed $count scans");
    $self->{logger}->debug("[thread $id] termination");
}

sub run {
    my ($self, %params) = @_;

    # Prepare client configuration in needed to send message to server
    $self->{_client_params} = {
        logger       => $self->{logger},
        user         => $params{user},
        password     => $params{password},
        proxy        => $params{proxy},
        ca_cert_file => $params{ca_cert_file},
        ca_cert_dir  => $params{ca_cert_dir},
        no_ssl_check => $params{no_ssl_check},
        no_compress  => $params{no_compress},
    } if !$self->{client};

    # check discovery methods available
    if (canRun('arp')) {
        $self->{arp} = 'arp -a';
    } elsif (canRun('ip')) {
        $self->{arp} = 'ip neighbor show';
    } else {
        $self->{logger}->info(
            "Can't run 'ip neighbor show' or 'arp' command, arp table detection can't be used"
        );
    }

    Net::Ping->require();
    if ($EVAL_ERROR) {
        $self->{logger}->info(
            "Can't load Net::Ping, echo ping can't be used"
        );
    }

    Net::NBName->require();
    if ($EVAL_ERROR) {
        $self->{logger}->info(
            "Can't load Net::NBName, netbios can't be used"
        );
    }

    FusionInventory::Agent::SNMP::Live->require();
    if ($EVAL_ERROR) {
        $self->{logger}->info(
            "Can't load FusionInventory::Agent::SNMP::Live, snmp detection " .
            "can't be used"
        );
    }

    # Extract greatest max_threads from jobs
    my ($max_threads) = sort { $b <=> $a } map { int($_->max_threads()) }
        @{$self->{jobs}};

    my %running_threads = ();
    my %queues = ();

    # initialize FIFOs
    my $jobs = Thread::Queue->new();
    my $done = Thread::Queue->new();

    # Start jobs by preparing range queues and counting ips
    my $max_count = 0;
    foreach my $job (@{$self->{jobs}}) {
        my $pid = $job->pid;

        my $queue = {
            max_in_queue        => $job->max_threads(),
            in_queue            => 0,
            timeout             => $job->timeout(),
            snmp_credentials    => $job->getValidCredentials(),
        };

        my $size = 0;
        my @list = ();

        # process each address block
        foreach my $range ($job->ranges()) {
            my $start = $range->{start};
            my $end   = $range->{end};
            my $block = Net::IP->new( "$start-$end" );
            if (!$block || $block->{binip} !~ /1/) {
                $self->{logger}->error(
                    "IPv4 range not supported by Net::IP: $start-$end"
                );
                next;
            }

            $self->{logger}->debug("scanning block $start-$end");

            # send initial message to the server
            $self->_sendStartMessage($pid);

            do {
                push @list, {
                    ip              => $block->ip(),
                    snmp_ports      => $range->{ports},
                    snmp_domains    => $range->{domains},
                    entity          => $range->{entity},
                };
            } while (++$block);

            # Update ip addresses size for this job
            $size += scalar(@list);
        }

        next unless $size;

        # Update queues
        $queue->{list} = \@list;
        $queues{$pid} = $queue;

        # Update total count
        $max_count += $size;

        # send block size to the server
        $self->_sendBlockMessage($pid, $size);
    }

    # Don't keep client until we created threads to avoid segfault if SSL is used
    # we older openssl libs, but only if it is still not set by a script
    delete $self->{client} if $self->{_client_params};

    # Define a realistic block scan expiration : at least one minute by address
    setExpirationTime( timeout => $max_count * 60 );
    my $expiration = getExpirationTime();

    # no need more threads than ips to scan
    my $threads_count = $max_threads > $max_count ? $max_count : $max_threads;

    $self->{logger}->debug("creating $threads_count worker threads");
    for (my $i = 0; $i < $threads_count; $i++) {
        my $newthread = threads->create(sub { $self->_discovery_thread($jobs, $done); });
        # Keep known created threads in a hash
        $running_threads{$newthread->tid()} = $newthread ;
        usleep(50000) until ($newthread->is_running() || $newthread->is_joinable());
    }

    # Check really started threads number vs really running ones
    my @really_running  = map { $_->tid() } threads->list(threads::running);
    my @started_threads = keys(%running_threads);
    unless (@really_running == $threads_count && keys(%running_threads) == $threads_count) {
        $self->{logger}->debug(scalar(@really_running)." really running: [@really_running]");
        $self->{logger}->debug(scalar(@started_threads)." started: [@started_threads]");
    }

    my $queued_count = 0;
    my $job_count = 0;
    my $jid_len = length(sprintf("%i",$max_count));
    my $jid_pattern = "#%0".$jid_len."i";

    # We need to guaranty we don't have more than max_in_queue device in shared
    # queue for each job
    while (my @pids = sort { $a <=> $b } keys(%queues)) {

        # Enqueue as ip as possible
        foreach my $pid (@pids) {
            my $queue = $queues{$pid};
            next unless @{$queue->{list}};
            next if $queue->{in_queue} >= $queue->{max_in_queue};
            my $address = shift @{$queue->{list}};
            # Update address hash with common parameters
            $address->{pid} = $pid;
            $address->{timeout} = $queue->{timeout};
            $address->{snmp_credentials} = $queue->{snmp_credentials};
            $address->{jid} = sprintf($jid_pattern, ++$job_count);
            $queue->{in_queue} ++;
            $jobs->enqueue($address);
            $queued_count++;
        }

        # as long as some of our threads are still running...
        if (keys(%running_threads)) {

            # send available results on the fly
            while (my $address = $done->dequeue_nb()) {
                my $pid = $address->{pid};
                my $queue = $queues{$pid};
                $queue->{in_queue} --;
                $queued_count--;
                unless ($queue->{in_queue} || @{$queue->{list}}) {
                    # send final message to the server before cleaning threads
                    $self->_sendStopMessage($pid);

                    delete $queues{$pid};

                    # send final message to the server
                    $self->_sendStopMessage($pid);
                }
                # Check if it's time to abort a thread
                $max_count--;
                if ($max_count < $threads_count) {
                    $jobs->enqueue({ leave => 1 });
                    $threads_count--;
                }
            }

            # wait for a little
            usleep(50000);

            if ($expiration && time > $expiration) {
                $self->{logger}->warning("Aborting netdiscovery task as it reached expiration time");
                # detach all our running worker
                foreach my $tid (keys(%running_threads)) {
                    $running_threads{$tid}->detach()
                        if $running_threads{$tid}->is_running();
                    delete $running_threads{$tid};
                }
                last;
            }

            # List our created and possibly running threads in a list to check
            my %running_threads_checklist = map { $_ => 0 }
                keys(%running_threads);

            foreach my $running (threads->list(threads::running)) {
                my $tid = $running->tid();
                # Skip if this running thread tid is not is our started list
                next unless exists($running_threads{$tid});

                # Check a thread is still running
                $running_threads_checklist{$tid} = 1 ;
            }

            # Clean our started list from thread tid that don't run anymore
            foreach my $tid (keys(%running_threads_checklist)) {
                delete $running_threads{$tid}
                    unless $running_threads_checklist{$tid};
            }
            last unless keys(%running_threads);
        }
    }

    if ($queued_count) {
        $self->{logger}->error("$queued_count devices scan result missed");
    }

    # Cleanup joinable threads
    $_->join() foreach threads->list(threads::joinable);
    $self->{logger}->debug("All netdiscovery threads terminated")
        unless threads->list(threads::running);

    # Reset expiration
    setExpirationTime();
}

sub abort {
    my ($self) = @_;

    $self->_sendStopMessage() if $self->{pid};
    $self->SUPER::abort();
}

sub _sendMessage {
    my ($self, $content) = @_;

    my $message = FusionInventory::Agent::XML::Query->new(
        deviceid => $self->{deviceid} || 'foo',
        query    => 'NETDISCOVERY',
        content  => $content
    );

    # task-specific client, if needed
    $self->{client} = FusionInventory::Agent::HTTP::Client::OCS->new(%{$self->{_client_params}})
        if !$self->{client};

    $self->{client}->send(
        url     => $self->{target}->getUrl(),
        message => $message
    );
}

sub _scanAddress {
    my ($self, $params) = @_;

    my $logger = $self->{logger};
    my $id     = threads->tid();
    $logger->{prefix} = "[thread $id] $params->{jid}, ";
    $logger->debug("scanning $params->{ip}");

    # Used by unittest to test arp cases
    $self->{arp} = $params->{arp} if $params->{arp};

    my %device = (
        $INC{'Net/SNMP.pm'}      ? $self->_scanAddressBySNMP($params)    : (),
        $INC{'Net/NBName.pm'}    ? $self->_scanAddressByNetbios($params) : (),
        $INC{'Net/Ping.pm'}      ? $self->_scanAddressByPing($params)    : (),
        $self->{arp}             ? $self->_scanAddressByArp($params)     : (),
    );

    # don't report anything without a minimal amount of information
    return unless
        $device{MAC}          ||
        $device{SNMPHOSTNAME} ||
        $device{DNSHOSTNAME}  ||
        $device{NETBIOSNAME};

    $device{IP} = $params->{ip};

    if ($device{MAC}) {
        $device{MAC} =~ tr/A-F/a-f/;
    }

    return \%device;
}

sub _scanAddressByArp {
    my ($self, $params) = @_;

    return unless $params->{ip};

    # We want to match the ip including non digit character around
    my $ip_match = '\b' . $params->{ip} . '\D';
    # We want to match dot on dots
    $ip_match =~ s/\./\\./g;

    # Just to handle unittests
    my %params = ( logger => $self->{logger} );
    $params{file} = $params->{file} if $params->{file};

    my $output = getFirstMatch(
        command => $self->{arp} . " " . $params->{ip},
        pattern => qr/^(.*$ip_match.*)$/,
        %params
    );

    my %device = ();

    if ($output && $output =~ /^(\S+) \(\S+\) at (\S+) /) {
        $device{DNSHOSTNAME} = $1 if $1 ne '?';
        $device{MAC}         = getCanonicalMacAddress($2);
    } elsif ($output && $output =~ /^\s+\S+\s+([:a-zA-Z0-9-]+)\s/) {
        # Under win32, mac address separators are minus signs
        my $mac_address = $1;
        $mac_address =~ s/-/:/g;
        $device{MAC} = getCanonicalMacAddress($mac_address);
    } elsif ($output && $output =~ /^\S+\s+dev\s+\S+\s+lladdr\s+([:a-zA-Z0-9-]+)\s/) {
        $device{MAC} = getCanonicalMacAddress($1);
    }

    $self->{logger}->debug(
        sprintf "- scanning %s in arp table: %s",
        $params->{ip},
        $device{MAC} ? 'success' : 'no result'
    );

    return %device;
}

sub _scanAddressByPing {
    my ($self, $params) = @_;

    my $type = 'echo';
    my $np = Net::Ping->new('icmp', 1);

    my %device = ();

    # Avoid an error as Net::Ping::VERSION may contain underscore
    my ($NetPingVersion) = split('_',$Net::Ping::VERSION);

    if ($np->ping($params->{ip})) {
        $device{DNSHOSTNAME} = $params->{ip};
    } elsif ($NetPingVersion >= 2.67) {
        $type = 'timestamp';
        $np->message_type($type);
        if ($np->ping($params->{ip})) {
            $device{DNSHOSTNAME} = $params->{ip};
        }
    }

    $self->{logger}->debug(
        sprintf "- scanning %s with $type ping: %s",
        $params->{ip},
        $device{DNSHOSTNAME} ? 'success' : 'no result'
    );

    return %device;
}

sub _scanAddressByNetbios {
    my ($self, $params) = @_;

    my $nb = Net::NBName->new();

    my $ns = $nb->node_status($params->{ip});

    $self->{logger}->debug(
        sprintf "- scanning %s with netbios: %s",
        $params->{ip},
        $ns ? 'success' : 'no result'
    );
    return unless $ns;

    my %device;
    foreach my $rr ($ns->names()) {
        my $suffix = $rr->suffix();
        my $G      = $rr->G();
        my $name   = $rr->name();
        if ($suffix == 0 && $G eq 'GROUP') {
            $device{WORKGROUP} = getSanitizedString($name);
        }
        if ($suffix == 3 && $G eq 'UNIQUE') {
            $device{USERSESSION} = getSanitizedString($name);
        }
        if ($suffix == 0 && $G eq 'UNIQUE') {
            $device{NETBIOSNAME} = getSanitizedString($name)
                unless $name =~ /^IS~/;
        }
    }

    $device{MAC} = $ns->mac_address();
    $device{MAC} =~ tr/-/:/;

    return %device;
}

sub _scanAddressBySNMP {
    my ($self, $params) = @_;

    my $tries = [];
    if ($params->{snmp_ports} && @{$params->{snmp_ports}}) {
        foreach my $port (@{$params->{snmp_ports}}) {
            my @cases = map { { port => $port, credential => $_ } } @{$params->{snmp_credentials}};
            push @{$tries}, @cases;
        }
    } else {
        @{$tries} = map { { credential => $_ } } @{$params->{snmp_credentials}};
    }
    if ($params->{snmp_domains} && @{$params->{snmp_domains}}) {
        my @domtries = ();
        foreach my $domain (@{$params->{snmp_domains}}) {
            foreach my $try (@{$tries}) {
                $try->{domain} = $domain;
            }
            push @domtries, @{$tries};
        }
        $tries = \@domtries;
    }

    foreach my $try (@{$tries}) {
        my $credential = $try->{credential};
        my $device = $self->_scanAddressBySNMPReal(
            ip         => $params->{ip},
            port       => $try->{port},
            domain     => $try->{domain},
            timeout    => $params->{timeout},
            credential => $credential
        );

        # no result means either no host, no response, or invalid credentials
        $self->{logger}->debug(
            sprintf "- scanning %s%s with SNMP%s, credentials %d: %s",
            $params->{ip},
            $try->{port}   ? ':'.$try->{port}   : '',
            $try->{domain} ? ' '.$try->{domain} : '',
            $credential->{ID},
            ref $device eq 'HASH' ? 'success' :
                $device ? "no result, $device" : 'no result'
        );

        if (ref $device eq 'HASH') {
            $device->{AUTHSNMP} = $credential->{ID};
            return %{$device};
        }
    }

    return;
}

sub _scanAddressBySNMPReal {
    my ($self, %params) = @_;

    my $snmp;
    eval {
        $snmp = FusionInventory::Agent::SNMP::Live->new(
            version      => $params{credential}->{VERSION},
            hostname     => $params{ip},
            port         => $params{port},
            domain       => $params{domain},
            timeout      => $params{timeout} || 1,
            community    => $params{credential}->{COMMUNITY},
            username     => $params{credential}->{USERNAME},
            authpassword => $params{credential}->{AUTHPASSPHRASE},
            authprotocol => $params{credential}->{AUTHPROTOCOL},
            privpassword => $params{credential}->{PRIVPASSPHRASE},
            privprotocol => $params{credential}->{PRIVPROTOCOL},
        );
    };

    # an exception here just means no device or wrong credentials
    return $EVAL_ERROR if $EVAL_ERROR;

    my $info = getDeviceInfo(
        snmp    => $snmp,
        datadir => $self->{datadir},
        logger  => $self->{logger},
    );
    return unless $info;

    return $info;
}

sub _sendStartMessage {
    my ($self, $pid) = @_;

    $self->_sendMessage({
        AGENT => {
            START        => 1,
            AGENTVERSION => $FusionInventory::Agent::Version::VERSION,
        },
        MODULEVERSION => $VERSION,
        PROCESSNUMBER => $pid
    });
}

sub _sendStopMessage {
    my ($self, $pid) = @_;

    $self->_sendMessage({
        AGENT => {
            END => 1,
        },
        MODULEVERSION => $VERSION,
        PROCESSNUMBER => $pid
    });
}

sub _sendBlockMessage {
    my ($self, $pid, $count) = @_;

    $self->_sendMessage({
        AGENT => {
            NBIP => $count
        },
        PROCESSNUMBER => $pid
    });
}

sub _sendResultMessage {
    my ($self, $result, $pid) = @_;

    $self->_sendMessage({
        DEVICE        => [$result],
        MODULEVERSION => $VERSION,
        PROCESSNUMBER => $pid
    });
}

1;

__END__

=head1 NAME

FusionInventory::Agent::Task::NetDiscovery - Net discovery support for FusionInventory Agent

=head1 DESCRIPTION

This tasks scans the network to find connected devices, allowing:

=over

=item *

devices discovery within an IP range, through arp, ping, NetBios or SNMP

=item *

devices identification, through SNMP

=back

This task requires a GLPI server with FusionInventory plugin.

=head1 AUTHORS

Copyright (C) 2009 David Durieux
Copyright (C) 2010-2012 FusionInventory Team
