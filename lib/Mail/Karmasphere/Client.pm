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

	IDT_IP4				=> 0,
	IDT_IP6				=> 1,
	IDT_DOMAIN			=> 2,
	IDT_EMAIL			=> 3,
	IDT_URL				=> 4,
};
use constant {
	AUTHENTIC					=> "a",
	SMTP_CLIENT_IP				=> "smtp.client-ip",
	SMTP_ENV_HELO				=> "smtp.env.helo",
	SMTP_ENV_MAIL_FROM			=> "smtp.env.mail-from",
	SMTP_ENV_RCPT_TO			=> "smtp.env.rcpt-to",
	SMTP_HEADER_FROM_ADDRESS	=> "smtp.header.from.address",

	FL_FACTS		=> 1,
};

BEGIN {
	@ISA = qw(Exporter);
	$VERSION = "2.04";
	@EXPORT_OK = qw(
					IDT_IP4_ADDRESS IDT_IP6_ADDRESS
					IDT_DOMAIN_NAME IDT_EMAIL_ADDRESS

					IDT_IP4 IDT_IP6
					IDT_DOMAIN IDT_EMAIL
					IDT_URL

					AUTHENTIC
					SMTP_CLIENT_IP
					SMTP_ENV_HELO SMTP_ENV_MAIL_FROM SMTP_ENV_RCPT_TO
					SMTP_HEADER_FROM_ADDRESS

					FL_FACTS
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

	unless ($self->{Socket}) {
		$self->{Proto} = 'udp'
						unless defined $self->{Proto};
		$self->{PeerAddr} = $self->{PeerHost}
						unless defined $self->{PeerAddr};
		$self->{PeerAddr} = 'query.karmasphere.com'
						unless defined $self->{PeerAddr};
		$self->{PeerPort} = 8666
						unless $self->{Port};
		$self->{Socket} = new IO::Socket::INET(
			Proto			=> $self->{Proto},
			PeerAddr		=> $self->{PeerAddr},
			PeerPort		=> $self->{PeerPort},
			ReuseAddr		=> 1,
		)
				or die "Failed to create socket: $! (%$self)";
	}

	if ($self->{Debug} and ref($self->{Debug}) ne 'CODE') {
		$self->{Debug} = sub { print STDERR Dumper(@_); };
	}
	$self->{Debug}->('new', $self) if $self->{Debug};

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

	$self->{Debug}->('send_query', $query) if $self->{Debug};

	my $id = $query->id;

	my $packet = {
		_	=> $id,
		i	=> $query->identities,
	};
	$packet->{s} = $query->composites if $query->has_composites;
	$packet->{f} = $query->feeds if $query->has_feeds;
	$packet->{c} = $query->combiners if $query->has_combiners;
	$packet->{fl} = $query->flags if $query->has_flags;
	# $self->{Debug}->('send_packet', $packet) if $self->{Debug};
	if (defined $self->{Principal}) {
		my $creds = defined $self->{Credentials} ? $self->{Credentials} : '';
		$packet->{a} = [ $self->{Principal}, $creds ];
	}

	my $data = bencode($packet);
	$self->{Debug}->('send_data', $data) if $self->{Debug};

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
		$self->{Debug}->('recv_data', $data) if $self->{Debug};
	}
	else {
		$socket->recv($data, 8192)
					or die "Failed to receive from socket: $!";
		$self->{Debug}->('recv_data', $data) if $self->{Debug};
	}
	my $packet = bdecode($data);
	die $packet unless ref($packet) eq 'HASH';

	my $response = new Mail::Karmasphere::Response($packet);
	$self->{Debug}->('recv_response', $response) if $self->{Debug};
	return $response;
}

sub recv {
	my ($self, $query, $timeout) = @_;

	my $id = ref($query) ? $query->id : $query;
	if ($QUEUE{$id}) {
		$self->{Debug}->('recv_find', $id, $QUEUE{$id})
						if $self->{Debug};
		@QUEUE = grep { $_ ne $id } @QUEUE;
		return delete $QUEUE{$id};
	}

	my $socket = $self->{Socket};

	$timeout = 10 unless defined $timeout;
	my $finish = time() + $timeout;
	my $select = new IO::Select();
	$select->add($socket);
	while ($timeout > 0) {
		my @ready = $select->can_read($timeout);

		if (@ready) {
			my $response = $self->_recv_real();
			$response->{query} = $query if ref $query;
			return $response if $response->id eq $id;

			my $rid = $response->id;
			push(@QUEUE, $rid);
			$QUEUE{$rid} = $response;
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
	$timeout = 5 unless defined $timeout;
	for (0..2) {
		my $id = $self->send($query);
		my $response = $self->recv($query, $timeout);
		# $response->{query} = $query;
		return $response if $response;
		$timeout += $timeout;
	}
	return undef;
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
	$query->identity('123.45.6.7', IDT_IP4);
	$query->composite('karmasphere.email-sender');
	my $response = $client->ask($query, 6);
	print $response->as_string;

	my $id = $client->send($query);
	my $response = $client->recv($query, 12);
	my $response = $client->recv($id, 12);

	my $response = $client->query(
		Identities	=> [ ... ]
		Composite	=> 'karmasphere.email-sender',
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
default is 'query.karmasphere.com'.

=item PeerPort

The TCP or UDP to contact. See L<IO::Socket::INET>. The default
is 8666.

=item Proto

Either 'udp' or 'tcp'. The default is 'udp' because it is faster.

=item Principal

An identifier used to authenticate client connections. This may be a
login or account name. The precise details will depend on the policy
of the query server being used.

=item Credentials

The credentials used to authenticate the principal. This may be a
password, or a certificate. The precise details may depend on the
policy of the query server being used.

=item Debug

Either a true value for debugging to stderr, or a custom debug handler.
The custom handler will be called with N arguments, the first of which
is a string 'debug context'. The custom handler may choose to ignore
messages from certain contexts.

=back

=head1 METHODS

=over 4

=item $response = $client->ask($query, $timeout)

Returns a L<Mail::Karmasphere::Response> to a
L<Mail::Karmasphere::Query>. The core of this method is equivalent to

	$client->recv($client->send($query), $timeout)

The method retries up to 3 times, doubling the timeout each time. If
the application requires more control over retries or backoff, it
should use send() and recv() individually. $timeout is optional.

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

=item IDT_IP4 IDT_IP6 IDT_DOMAIN IDT_EMAIL IDT_URL

Identity type constants.

=item AUTHENTIC SMTP_CLIENT_IP SMTP_ENV_HELO SMTP_ENV_MAIL_FROM SMTP_ENV_RCPT_TO SMTP_HEADER_FROM_ADDRESS

Identity tags, indicating the context of an identity to the server.

=item FL_FACTS

A flag indicating that all facts must be returned explicitly in the
Response.

=back

=head1 BUGS

UDP retries are not yet implemented.

=head1 SEE ALSO

L<Mail::Karmasphere::Query>,
L<Mail::Karmasphere::Response>,
http://www.karmasphere.com/,
L<Mail::SpamAssassin::Plugin::Karmasphere>

=head1 COPYRIGHT

Copyright (c) 2005-2006 Shevek, Karmasphere. All rights reserved.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
