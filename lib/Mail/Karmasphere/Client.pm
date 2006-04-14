package Mail::Karmasphere::Client;

use strict;
use warnings;
use vars qw($VERSION @ISA @EXPORT_OK %EXPORT_TAGS);
use Exporter;
use Data::Dumper;
use Convert::Bencode qw(bencode bdecode);
use IO::Socket::INET;
use constant {
	IDT_IP4_ADDRESS		=> 0,
	IDT_IP6_ADDRESS		=> 1,
	IDT_DOMAIN_NAME		=> 2,
	IDT_EMAIL_ADDRESS	=> 3,
	IDT_URL				=> 4,
};

BEGIN {
	@ISA = qw(Exporter);
	$VERSION = "1.09";
	@EXPORT_OK = qw(
					IDT_IP4_ADDRESS IDT_IP6_ADDRESS
					IDT_DOMAIN_NAME IDT_EMAIL_ADDRESS
					IDT_URL
				);
	%EXPORT_TAGS = (
		'all' => \@EXPORT_OK,
		'ALL' => \@EXPORT_OK,
	);
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

sub ask {
	my ($self, $query) = @_;

	die "Not blessed reference: $query"
			unless ref($query) =~ /[a-z]/;
	die "Not a query: $query"
			unless $query->isa('Mail::Karmasphere::Query');

	print STDERR Dumper($query) if $self->{Debug};

	my $packet = {
		_	=> $query->id,
		i	=> $query->identities,
	};
	$packet->{s} = $query->composites if defined $query->composites;
	$packet->{f} = $query->feeds if defined $query->feeds;
	$packet->{c} = $query->combiners if defined $query->combiners;
	$packet->{fl} = $query->flags if defined $query->flags;
	print STDERR Dumper($packet) if $self->{Debug};

	my $data = bencode($packet);
	print STDERR Dumper($data) if $self->{Debug};

	if ($self->{Proto} eq 'tcp') {
		$data = pack("N", length($data)) . $data;
	}

	my $socket = $self->{Socket};
	$socket->send($data)
					or die "Failed to send to socket: $!";
	my $response;
	if ($self->{Proto} eq 'tcp') {
		my $data;
		$socket->read($data, 4)
					or die "Failed to receive length from socket: $!";
		my $length = unpack("N", $data);
		$socket->read($response, $length)
					or die "Failed to receive data from socket: $!";
	}
	else {
		$socket->recv($response, 8192)
					or die "Failed to receive from socket: $!";
	}
	my $result = bdecode($response);
	die $result unless ref($result) eq 'HASH';
	$result->{query} = $query;

	return new Mail::Karmasphere::Response($result);
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
	$query->combiner('karmasphere.emailchecker');
	my $response = $client->ask($query);
	print $response->as_string;

	my $response = $client->query(...);

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

=item $response = $client->ask($query)

Returns a L<Mail::Karmasphere::Response> to a
L<Mail::Karmasphere::Query>.

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
