package Munin::Master::Node;

use warnings;
use strict;

use Carp;
use Munin::Master::Config;
use Munin::Common::Timeout;
use Munin::Common::TLSClient;
use Munin::Master::Logger;

my $config = Munin::Master::Config->instance();


sub new {
    my ($class, $address, $port, $host) = @_;

    my $self = {
        address => $address,
        port    => $port,
        host    => $host,
        tls     => undef,
        socket  => undef,
        master_capabilities => qw(foo),
        io_timeout => 5,
    };

    return bless $self, $class;
}


sub do_in_session {
    my ($self, $block) = @_;

    $self->_do_connect();
    $self->_run_starttls_if_required();
    $block->();
    $self->_do_close();
}


sub _do_connect {
    my ($self) = @_;

    $self->{socket} = IO::Socket::INET->new(
        PeerAddr  => $self->{address},
        PeerPort  => $self->{port},
        LocalAddr => $config->{local_address},
        Proto     => 'tcp', 
        Timeout   => $config->{timeout},
    ) or croak "Failed to create socket: $!";

    my $greeting = $self->_node_read_single();
    $self->{node_name} = $self->_extract_name_from_greeting($greeting);
}


sub _extract_name_from_greeting {
    my ($self, $greeting) = @_;
    croak "Got no reply from node" unless $greeting;
    $greeting =~ /\#.*(?:lrrd|munin) (?:client|node) at (\S+)/
        or croak "Got unknown reply from node";
    return $1;
}


sub _run_starttls_if_required {
    my ($self) = @_;

    # TLS should only be attempted if explicitly enabled. The default
    # value is therefore "disabled" (and not "auto" as before).
    my $tls_requirement = $config->{tls};
    logger("[DEBUG] TLS set to \"$tls_requirement\".") if $config->{debug};
    return if $tls_requirement eq 'disabled';
    $self->{tls} = Munin::Common::TLSClient->new({
        DEBUG        => $config->{debug},
        logger       => \&logger,
        read_fd      => fileno($self->{socket}),
        read_func    => sub { _node_read_single($self) },
        tls_ca_cert  => $config->{tls_ca_certificate},
        tls_cert     => $config->{tls_certificate},
        tls_paranoia => $tls_requirement, 
        tls_priv     => $config->{tls_private_key},
        tls_vdepth   => $config->{tls_verify_depth},
        tls_verify   => $config->{tls_verify_certificate},
        write_fd     => fileno($self->{socket}),
        write_func   => sub { _write_socket_single($self, @_) },
    });

    if (!$self->{tls}->start_tls()) {
        $self->{tls} = undef;
        if ($tls_requirement eq "paranoid" or $tls_requirement eq "enabled") {
            croak("[ERROR] Could not establish TLS connection to '$self->{address}'. Skipping.");
        }
    }
}


sub _do_close {
    my ($self) = @_;
    
    close $self->{socket};
    $self->{socket} = undef;
}


sub negotiate_capabilities {
    my ($self) = @_;

    $self->_node_write_single("cap $self->{master_capabilities}\n");
    my @lines = $self->_node_read();

    if (index($lines[0], '# Unknown command') == 0) {
        return ('NA');
    }

    my $node_capabilities = substr $lines[0], 2, index($lines[0], ')');
    my $session_capabilities = $lines[1];

    logger("[DEBUG] $node_capabilities") if $config->{debug};
    logger("[DEBUG] Session capabilities: $session_capabilities") 
        if $config->{debug};

    return split / /, $session_capabilities;
}


sub list_services {
    my ($self) = @_;
    
    my $host = $config->{groups_and_hosts}{$self->{host}}{use_node_name} 
        ? $self->{node_name}
        : $self->{host};

    croak "Couldn't find out which host to list" unless $host;

    $self->_node_write_single("list $host\n");
    my $list = $self->_node_read_single();
    
    return split / /, $list;
}


sub fetch_service_config {
    my ($self, $service) = @_;

    logger("[DEBUG] Fetching service configuration for '$service'")
        if $config->{debug};
    $self->_node_write_single("config $service\n");

    my @lines = $self->_node_read();
    
    my @global_config = ();
    my %data_source_config = ();

    my @graph_order = ();

    for my $line (@lines) {
        croak "Client reported timeout in configuration of '$service'"
            if $line =~ /\# timeout/;
        next unless $line;
        next if $line =~ /^\#/;
        
        if ($line =~ m{\A (\w+)\.(\w+) \s+ (.+) }xms) {
            my ($ds_name, $ds_var, $ds_val) = ($1, $2, $3);
            $ds_name = $self->_sanitise_fieldname($ds_name);
            $data_source_config{$ds_name} ||= {};
            $data_source_config{$ds_name}{$ds_var} = $ds_val;
            logger("config: $service->$ds_name.$ds_var = $ds_val") if $config->{debug};
            push @graph_order, $ds_name if ($ds_var eq 'label');
        } 
        elsif ($line =~ m{\A (\w+) \s+ (.+) }xms) {
            push @global_config, [$1, $2];
            logger ("Config: $service->$1 = $2") if $config->{debug};
        }
        else {
            croak "Protocol exception: unrecognised line '$line'";
        }
    }

    $self->_validate_data_sources(\%data_source_config);

    push @global_config, ['graph_order', join(' ', @graph_order)]
        unless !@graph_order || grep { $_->[0] eq 'graph_order' } @global_config;

    return (global => \@global_config, data_source => \%data_source_config);
}


sub _validate_data_sources {
    my ($self, $data_source_config) = @_;

    for my $ds (keys %$data_source_config) {
        croak "Missing required attribute 'label' for data source '$ds'"
            unless defined $data_source_config->{$ds}{label};
    }
}

sub fetch_service_data {
    my ($self, $service) = @_;

    $self->_node_write_single("fetch $service\n");
    my @lines = $self->_node_read();

    my %values = ();

    for my $line (@lines) {
        croak "Client reported timeout in configuration of '$service'"
            if $line =~ /\# timeout/;
        next unless $line;
        next if $line =~ /^\#/;
        
        if ($line =~ m{ (\w+)\.value \s+ ([\S:]+) }xms) {
            my ($data_source, $value, $when) = ($1, $2, 'N');

            $data_source = $self->_sanitise_fieldname($data_source);

	    if ($value =~ /^(\d+):(.+)$/) {
		$when = $1;
		$value = $2;
	    }

            $values{$data_source} = { value => $value, when => $when };
        }
        else {
            croak "Protocol exception: unrecogniced line '$line'";
        }
    }

    return %values;
}


sub _sanitise_fieldname {
    my ($self, $name) = @_;

    $name =~ s/[\W-]/_/g;
    return substr($name, -18);
}


sub _node_write_single {
    my ($self, $text) = @_;

    logger("[DEBUG] Writing to socket: \"$text\".") if $config->{debug};
    my $timed_out = !do_with_timeout($self->{io_timeout}, sub { 
        if ($self->{tls} && $self->{tls}->session_started()) {
            $self->{tls}->write($text)
                or exit 9;
        }
        else {
            print { $self->{socket} } $text;
        }
    });
    if ($timed_out) {
        logger("[WARNING] Socket write timed out\n");
        return;
    }
    return 1;
}

sub _node_read_single {
    my ($self) = @_;
    my $res;

    my $timed_out = !do_with_timeout($self->{io_timeout}, sub { 
      if ($self->{tls} && $self->{tls}->session_started()) {
          $res = $self->{tls}->read();
      }
      else {
          $res = readline $self->{socket};
      }
      chomp $res if defined $res;
    });
    if ($timed_out) {
        logger("[WARNING] Socket read timed out\n");
        return;
    }
    logger("[DEBUG] Reading from socket: \"$res\".") if $config->{debug};
    return $res;
}


sub _node_read {
    my ($self) = @_;
    my @array = (); 

    my $timed_out = !do_with_timeout($self->{io_timeout}, sub { 
        while (1) {
            my $line = $self->{tls} && $self->{tls}->session_started()
                ? $self->{tls}->read()
                : readline $self->{socket};
            last unless defined $line;
            last if $line =~ /^\.\n$/;
            chomp $line;
            push @array, $line;
        }
    });
    if ($timed_out) {
        logger ("[WARNING] Socket read timed out: $@\n");
        return;
    }
    logger ("[DEBUG] Reading from socket: \"".(join ("\\n",@array))."\".") if $config->{debug};
    return @array;
}


1;


__END__

=head1 NAME

Munin::Master::Node - Provides easy access to the munin node

=head1 SYNOPSIS

 use Munin::Master::Node;
 my $node = Munin::Master::Node->new('localhost', '4949', 'foo');
 $node->do_in_session(sub{
     ... # Call misc. methods on $node
 });

=head1 METHODS

=over

=item B<new>

FIX

=item B<do_in_session>

FIX

=item B<negotiate_capabilities>

FIX

=item B<list_services>

FIX

=item B<fetch_service_config>

FIX

=item B<fetch_service_data>

FIX

=back
