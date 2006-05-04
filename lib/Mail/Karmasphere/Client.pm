package Mail::Karmasphere::Client;

use strict;
use warnings;
use vars qw($VERSION @ISA @EXPORT_OK %EXPORT_TAGS
				%QUEUE @QUEUE $QUEUE);
use Exporter;
use Data::Dumper;
use Convert::Bencode qw(bencode bdecode);
use IO::Socket::INET;
use Time::HiRes;
use IO::Select;
use constant {
	IDT_IP4_ADDRESS		=> 0,
	IDT_IP6_ADDRESS		=> 1,
	IDT_DOMAIN_NAME		=> 2,
	IDT_EMAIL_ADDRESS	=> 3,
	IDT_URL				=> 4,
};

BEGIN {
	@ISA = qw(Exporter);
	$VERSION = "1.10";
	@EXPORT_OK = qw(
					IDT_IP4_ADDRESS IDT_IP6_ADDRESS
					IDT_DOMAIN_NAME IDT_EMAIL_ADDRESS
					IDT_URL
				);
	%EXPORT_TAGS = (
		'all' => \@EXPORT_OK,
		'ALL' => \@EXPORT_OK,
	);
	%QUEUE = ();
	@QUEUE = ();
	$QUEUE = 100;
}

# We can't use these until we set up the above variables.
use Mail::Karmasphere::Query;
use Mail::Karmasphere::Response;

sub new {
	my $class = shift;
	my $self = ($#_ == 0) ? { %{ (shift) } } : { @_ };

	$self->{Proto} ||= 'udp';
	unless ($self->{Socket}) {
		$self->{Socket} = new IO::Socket::INET(
			Proto           => $self->{Proto},
			PeerAddr        => $self->{PeerAddr}
							|| $self->{PeerHost}
							|| 'slave.karmasphere.com',
			PeerPort        => $self->{PeerPort} || 8666,
			ReuseAddr       => 1,
		)
				or die "Failed to create socket: $! (%$self)";
	}

	return bless $self, $class;
}

sub query {
	my $self = shift;
	return $self->ask(new Mail::Karmasphere::Query(@_));
}

sub send {
	my ($self, $query) = @_;

	die "Not blessed reference: $query"
			unless ref($query) =~ /[a-z]/;
	die "Not a query: $query"
			unless $query->isa('Mail::Karmasphere::Query');

	print STDERR Dumper($query) if $self->{Debug};

	my $id = $query->id;

	my $packet = {
		_	=> $id,
		i	=> $query->identities,
	};
	$packet->{s} = $query->composites if defined $query->composites;
	$packet->{f} = $query->feeds if defined $query->feeds;
	$packet->{c} = $query->combiners if defined $query->combiners;
	$packet->{fl} = $query->flags if defined $query->flags;
	# print STDERR Dumper($packet) if $self->{Debug};

	my $data = bencode($packet);
	print STDERR ">> $data\n" if $self->{Debug};

	if ($self->{Proto} eq 'tcp') {
		$data = pack("N", length($data)) . $data;
	}

	my $socket = $self->{Socket};
	$socket->send($data)
					or die "Failed to send to socket: $!";
	return $id;
}

sub _recv_real {
	my $self = shift;

	my $socket = $self->{Socket};

	my $data;
	if ($self->{Proto} eq 'tcp') {
		my $data;
		$socket->read($data, 4)
					or die "Failed to receive length from socket: $!";
		my $length = unpack("N", $data);
		$data = '';
		while ($length > 0) {
			my $block;
			my $bytes = $socket->read($block, $length)
						or die "Failed to receive data from socket: $!";
			$data .= $block;
			$length -= $bytes;
		}
		print STDERR "<< $data\n" if $self->{Debug};
	}
	else {
		$socket->recv($data, 8192)
					or die "Failed to receive from socket: $!";
	}
	my $packet = bdecode($data);
	die $packet unless ref($packet) eq 'HASH';

	my $response = new Mail::Karmasphere::Response($packet);
	print STDERR Dumper($response) if $self->{Debug};
	return $response;
}

sub recv {
	my ($self, $query, $timeout) = @_;

	my $id = ref($query) ? $query->id : $query;
	if ($QUEUE{$id}) {
		@QUEUE = grep { $_ ne $id } @QUEUE;
		return delete $QUEUE{$id};
	}

	my $socket = $self->{Socket};

	$timeout = 60 unless defined $timeout;
	my $finish = time() + $timeout;
	my $select = new IO::Select();
	$select->add($socket);
	while ($timeout > 0) {
		my @ready = $select->can_read($timeout);

		if (@ready) {
			my $response = $self->_recv_real();
			$response->{query} = $query if ref $query;
			return $response if $response->id eq $id;

			push(@QUEUE, $id);
			$QUEUE{$id} = $response;
			if (@QUEUE > $QUEUE) {
				my $oid = shift @QUEUE;
				delete $QUEUE{$oid};
			}
		}

		$timeout = $finish - time();
	}

	return undef;
}

sub ask {
	my ($self, $query, $timeout) = @_;
	my $id = $self->send($query);
	my $response = $self->recv($query, $timeout);
	# $response->{query} = $query;
	return $response;
}

=head1 NAME

Mail::Karmasphere::Client - Client for Karmasphere Reputation Server

=head1 SYNOPSIS

	use Mail::Karmasphere::Client qw(:all);

	my $client = new Mail::Karmasphere::Client(
			PeerAddr	=> '123.45.6.7',
			PeerPort	=> 8666,
				);

	my $query = new Mail::Karmasphere::Query();
	$query->identity('123.45.6.7', IDT_IP4_ADDRESS);
	$query->composite('karmasphere.emailchecker');
	my $response = $client->ask($query, 60);
	print $response->as_string;

	my $id = $client->send($query);
	my $response = $client->recv($query, 60);
	my $response = $client->recv($id, 60);

	my $response = $client->query(
		Identities	=> [ ... ]
		Composite	=> 'karmasphere.emailchecker',
			);

=head1 DESCRIPTION

The Perl Karma Client API consists of three objects: The Query, the
Response and the Client. The user constructs a Query and passes it
to a Client, which returns a Response.

=head1 CONSTRUCTOR

The class method new(...) constructs a new Client object. All arguments
are optional. The following parameters are recognised as arguments
to new():

=over 4

=item PeerAddr

The IP address or hostname to contact. See L<IO::Socket::INET>. The
default is 'slave.karmasphere.com'.

=item PeerPort

The TCP or UDP to contact. See L<IO::Socket::INET>. The default
is 8666.

=item Proto

Either 'udp' or 'tcp'. The default is 'udp' because it is faster.

=item Debug

Set to 1 to enable some wire-level debugging.

=back

=head1 METHODS

=over 4

=item $response = $client->ask($query, $timeout)

Returns a L<Mail::Karmasphere::Response> to a
L<Mail::Karmasphere::Query>. This is equivalent to

	$client->recv($client->send($query), $timeout)

=item $id = $client->send($query)

Sends a L<Mail::Karmasphere::Query> to the server, and returns the
id of the query, which may be passed to recv().

=item $response = $client->recv($id, $timeout)

Returns a L<Mail::Karmasphere::Response> to the query with id $id,
assuming that the query has already been sent using send(). If no
matching response is read before the timeout, undef is returned.

=item $response = $client->query(...)

A convenience method, equivalent to

	$client->ask(new Mail::Karmasphere::Query(...));

See L<Mail::Karmasphere::Query> for more details.

=back

=head1 EXPORTS

=over 4

=item IDT_IP4_ADDRESS IDT_IP6_ADDRESS IDT_DOMAIN_NAME IDT_EMAIL_ADDRESS IDT_URL

Identity type constants.

=back

=head1 BUGS

This document is incomplete.

=head1 SEE ALSO

L<Mail::Karmasphere::Query>
L<Mail::Karmasphere::Response>
http://www.karmasphere.com/

=head1 COPYRIGHT

Copyright (c) 2005 Shevek, Karmasphere. All rights reserved.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
