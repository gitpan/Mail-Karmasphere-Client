
package Mail::SpamAssassin::Plugin::Karmasphere;

use strict;
use warnings;
use vars qw(@ISA $CONNECT_FEEDSET $CONTENT_FEEDSET $DEBUG);
use bytes;
use Carp qw(confess);
use Data::Dumper;
use Time::HiRes;
use Mail::SpamAssassin::Plugin;
use Mail::SpamAssassin::Logger;
use Mail::Karmasphere::Client qw(:ALL);

@ISA = qw(Mail::SpamAssassin::Plugin);
$CONNECT_FEEDSET = 'karmasphere.emailchecker';
$CONTENT_FEEDSET = 'karmasphere.contentfilter';
$DEBUG = undef;

# constructor: register the eval rule and parse any config
sub new {
	my $class = shift;
	my $mailsaobject = shift;

	my $self = $class->SUPER::new($mailsaobject, @_);

	my $conf = $mailsaobject->{conf};

	#$self->register_eval_rule("check_against_karma_db");

	$self->set_config($mailsaobject->{conf});

	$self->register_eval_rule("check_karma_range");

	return $self;
}

########################################################################

sub set_config {
	my ($self, $conf) = @_;
	my @cmds = ();

	push(@cmds, {
		setting		=> 'karma_feedset',
		code		=> sub {
			my $self = shift;
			my ($key, $value, $line) = @_;
			if ($value =~ /^(\S+)\s+(\S+)$/) {
				my ($context, $composite) = ($1, $2);
				$self->{karma_feedset}->{$context} = $composite;
			}
			elsif (! length $value) {
				return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
			}
			else {
				return $Mail::SpamAssassin::Conf::INVALID_VALUE;
			}
		},
	});

	push (@cmds, {
		setting		=> 'karma_range',
		code		=> sub {
			my $self = shift;
			my ($key, $value, $line) = @_;
			if ($value =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/) {
				my ($rulename, $context, $min, $max) =
								($1, $2, 0+$3, 0+$4);
				$self->{karma_rules}->{$rulename} =
								[ $context, $min, $max ];
				$self->{parser}->add_test($rulename,
						"check_karma_range('$context', '$min', '$max')",
						$Mail::SpamAssassin::Conf::TYPE_FULL_EVALS);
			}
			elsif (! length $value) {
				return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
			}
			else {
				return $Mail::SpamAssassin::Conf::INVALID_VALUE;
			}
		},
	});

	push (@cmds, {
		setting		=> 'karma_host',
		default		=> 'slave.karmasphere.com',
		is_admin	=> 1,
		type		=> $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	});

	push (@cmds, {
		setting		=> 'karma_port',
		default		=> '8666',
		is_admin	=> 1,
		type		=> $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
	});

	push (@cmds, {
		setting		=> 'karma_timeout',
		default		=> '15',
		is_admin	=> 1,
		type		=> $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
	});

	push (@cmds, {
		setting		=> 'karma_ar_host',
		is_admin	=> 1,
		type		=> $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	});

	$conf->{parser}->register_commands(\@cmds);
}

sub _karma_debug {
	my ($context, @args) = @_;
	{
		local $Data::Dumper::Indent = 1;
		local $Data::Dumper::Varname = uc($context);
		dbg("karma: " . Dumper(@args));
	}
	$DEBUG->(@_) if $DEBUG;
}

sub _karma_client {
	my $self = shift;
	my $conf = shift || $self->{main}{conf};
	unless ($self->{Client}) {
		my %args = (
			PeerHost	=> $conf->{karma_host},
			PeerPort	=> $conf->{karma_port},
		);
		if (would_log('dbg', 'karma')) {
			$args{Debug} = \&_karma_debug;
		}
		$self->{Client} = new Mail::Karmasphere::Client(%args);
	}
	return $self->{Client};
}

sub add_connect_authentication {
	my ($self, $scanner, $query) = @_;

	my $conf = $scanner->{conf};
	my $arhost = lc $conf->{karma_ar_host};

	# Authentication-Results: spf.checker.net \
	#	smtp.mail=spf-sender\@that.net; spf=pass

	# XXX Make sure these are not preceded by any received: line.
	my $authresults = $scanner->get('Authentication-Results');
	if (defined $authresults) {
		my @authresults = split(/[\r\n]+/, $authresults);
		foreach my $line (@authresults) {
			unless ($line =~ s/^\s*(\S+)\s*//) {
				dbg("Invalid Authentication-Results header: $line");
				next;
			}
			my $hostname = $1;
			if ($arhost) {
				next if $arhost eq lc $hostname;
			}
			my @vals = split(/\s*;\s*/, $line);
			my $identity = shift @vals;
			unless ($identity =~ /^([^=]*)=(.*)/) {
				dbg("Invalid Authentication-Results identity: $identity");
				next;
			}
			my ($artype, $iddata) = ($1, $2);
			my %checks = ();
			my $pass = undef;
			for my $val (@vals) {
				unless ($val =~ /^([^=]*)=(.*)/) {
					dbg("Invalid Authentication-Results result: $val");
					next;
				}
				$checks{$1} = $2;
				$pass++ if $2 =~ /^pass/;
			}
			my @tags;
			my $idtype;
			if ($artype eq 'smtp.mail') {
				$idtype = IDT_EMAIL_ADDRESS;
				push(@tags, SMTP_ENV_MAIL_FROM);
			}
			elsif ($artype eq 'header.from') {
				$idtype = IDT_EMAIL_ADDRESS;
				push(@tags, SMTP_HEADER_FROM_ADDRESS);
			}
			else {
				$idtype = guess_identity_type($iddata);
			}
			push(@tags, AUTHENTIC) if $pass;
			$query->identity($iddata, $idtype, @tags);
			# print Dumper($hostname, $idtype, $iddata, \%checks);
		}
	}
}

sub add_connect_received {
	my ($self, $scanner, $query) = @_;

	if ($scanner->{num_relays_untrusted} > 0) {
		my $lasthop = $scanner->{relays_untrusted}->[0];
		# print STDERR "Last hop is " . Dumper($lasthop);
		if (!defined $lasthop) {
			dbg("karma: message was delivered entirely via trusted relays, not required");
			return;
		}
		my $ip = $lasthop->{ip};
		$query->identity($ip, IDT_IP4_ADDRESS, SMTP_CLIENT_IP)
						if $ip;
		my $helo = $lasthop->{lc_helo} || $lasthop->{lc_rdns};
		$query->identity($helo, IDT_DOMAIN_NAME, SMTP_ENV_HELO)
						if $helo;
	}
}

sub add_connect_envfrom {
	my ($self, $scanner, $query) = @_;

	my $envfrom = $scanner->get('EnvelopeFrom:addr');
	$query->identity($envfrom, IDT_EMAIL_ADDRESS, SMTP_ENV_MAIL_FROM)
					if $envfrom;
}

sub add_connect_other {
	my ($self, $scanner, $query) = @_;
}

sub add_content_urls {
	my ($self, $scanner, $query) = @_;

	my $uris = $scanner->get_uri_detail_list();
	my %uris = ();
	for my $data (values %$uris) {
		my $cleaned = $data->{cleaned} or next;
		my $uri = $cleaned->[1] or next;
		$uris{$uri} = 1;
	}

	for my $uri (keys %uris) {
		$query->identity($uri, IDT_URL);
	}
}

sub add_content_other {
	my ($self, $scanner, $query) = @_;
}

sub _karma_send {
	my ($self, $scanner) = @_;

	my $conf = $scanner->{conf};
	my $client = $self->_karma_client($conf);

	# Now we have to navigate the twists and turns of the SpamAssassin
	# API to retrieve the message metadata we want. This is largely
	# inconsistent, and I hope it holds up.

	# The connection-time dance
	{
		my $query = new Mail::Karmasphere::Query();
		$query->composite($conf->{karma_feedset}->{connect}
						|| $CONNECT_FEEDSET);

		$self->add_connect_authentication($scanner, $query);
		$self->add_connect_received($scanner, $query);
		$self->add_connect_envfrom($scanner, $query);
		$self->add_connect_other($scanner, $query);

		if ($query->has_identities) {
			my $qid = $client->send($query);
			$scanner->{karma}->{id}->{connect} = $qid;
		}
	}

	# The content-filtering dance
	{
		my $query = new Mail::Karmasphere::Query();
		$query->composite($conf->{karma_feedset}->{content}
						|| $CONTENT_FEEDSET);

		$self->add_content_urls($scanner, $query);
		$self->add_content_other($scanner, $query);

		if ($query->has_identities) {
			my $qid = $client->send($query);
			$scanner->{karma}->{id}->{content} = $qid;
		}
	}

}


sub _karma_recv {
	my ($self, $scanner) = @_;

	dbg("_karma_recv: called");

	my $conf = $scanner->{conf};
	my $client = $self->_karma_client($conf);

	my $timeout = $conf->{karma_timeout};
	dbg("_karma_recv: timeout=$timeout");
	my $finish = time() + $timeout;
	my $id_connect = $scanner->{karma}->{id}->{connect};
	my $response_connect = undef;
	if ($id_connect) {
		dbg("_karma_recv: id_connect=$id_connect");
		$response_connect = $client->recv($id_connect, $timeout);
		# This warns about undefined if it times out.
		# dbg("_karma_recv: response_connect=$response_connect");
	}

	my $id_content = $scanner->{karma}->{id}->{content};
	my $response_content = undef;
	if ($id_content) {
		dbg("_karma_recv: id_content=$id_content");
		$response_content = $client->recv($id_content,
						$finish - time());
		# This warns about undefined if it times out.
		# dbg("_karma_recv: response_content=$response_content");
	}

	return {
		connect	=> $response_connect,
		content	=> $response_content,
	};
}

# The two hooks

sub parsed_metadata {
	my ($self, $opts) = @_;
	return if $self->{main}->{local_tests_only};

	my $scanner = $opts->{permsgstatus} or confess "No scanner!";
	$self->_karma_send($scanner);

	return undef;
}

sub check_post_dnsbl {
	my ($self, $opts) = @_;
	return if $self->{main}->{local_tests_only};

	my $scanner = $opts->{permsgstatus} or confess "No scanner!";
	my $conf = $scanner->{conf};

	my $responses = $self->_karma_recv($scanner);

	# return unless keys %$responses;

	my %values;
	my %data;
	while (my ($context, $response) = each(%$responses)) {
		next unless $response;
		my $composite = $conf->{karma_feedset}->{$context};
		my $value = $response->value($composite);
		$values{$context} = $value;
		my $data = $response->data($composite);
		$data{$context} = $data;
	}

	# Do something with closures.
	$scanner->set_tag("KARMASCORE", sub {
		my $context = shift;
		return $values{$context} if defined $values{$context};
		return '0';
	});
	$scanner->set_tag("KARMADATA", sub {
		my $context = shift;
		return $data{$context} if defined $data{$context};
		return '(null data)';
	});

	# print STDERR Dumper(\%values);
	return unless $conf->{karma_rules};
	# return unless keys %values;

	my %rules = %{ $conf->{karma_rules} };
	while (my ($rulename, $data) = each(%rules)) {
		my ($context, $min, $max) = @$data;
		# my $response = $responses->{$context};
		# next unless $response;
		# my $composite = $conf->{karma_feedset}->{$context};
		# my $value = $response->value($composite);
		# print STDERR Dumper('feedset', $composite, $value);
		my $value = $values{$context};
		next unless defined $value;
		next if $value < $min;
		next if $value > $max;
		$scanner->got_hit($rulename);
	}

	return undef;
}

# This doesn't do anything.
sub check_karma_range {
	my ($self, $scanner, $message, $key, $min, $max) = @_;
	return 0;
}

########################################################################

=head1 NAME

Mail::SpamAssassin::Plugin::Karmasphere - Query the Karmasphere reputation system

=head1 SYNOPSIS

	loadplugin Mail::SpamAssassin::Plugin::Karmasphere

	karma_feedset connect karmasphere.emailchecker
	karma_range KARMA_CONNECT_0_10	connect 0 10
	score KARMA_CONNECT_0_10	0.1

=head1 DESCRIPTION

The Karmasphere reputation service is a real-time reputation service
for identities. The aim of this plugin is to detect identities used
by spammers and phishers, and thus detect zero-day spam runs and
phishing scams.

This plugin performs lookups against the Karmasphere reputation
service. Two lookups are performed: One on the connect-time identities
(client-ip, helo-address and envelope-from) and one on any identities
found in the body of the message. Of these, the first is relatively
trustworthy, since it works (where possible) with authenticated
identities. The second works with unathenticated identities, but
should still trap URLs used by spammers and phishing sites.

=head1 USER SETTINGS

An extremely simplistic, minimal example configuration file is provided
in the eg/spamassassin/ subdirectory of this distribution. An
administrator would be expected to write a more complex
configuration file including more useful score ranges. The details
of a particular configuration file will depend on the choice of
feedsets used for the various context.

The very similar-looking words 'context', 'connect' and 'content'
are used throughout this document. Please read carefully.

Valid B<contexts> are B<connect>, for a karma query relating to
connection-time metadata, and B<content> for content-filtering data.

=over 4

=item B<karma_range> rulename context min max

A karma score range. B<context> is either B<connect> or B<content>

=item B<karma_feedset> context feedsetname

The feedset name to query in the given context information.  The
default for the B<connect> context is C<karmasphere.emailchecker>.
The default for the B<content> filter context is
C<karmasphere.contentfilter>.

=back

=head1 ADMINISTRATOR SETTINGS

=over 4

=item B<karma_host>

Hostname or IP address of the Karmasphere slave server.
The default is C<slave.karmasphere.com>.

=item B<karma_port>

Port number of the Karmasphere slave server.
The default is C<8666>.

=item B<karma_timeout>

The timeout for receiving karma responses, in seconds.
The default is C<15>.

=back

=head1 TEMPLATE TAGS

This module adds two extra template tags for header rewriting:
_KARMASCORE(C<context>)_ and _KARMADATA(C<context>)_, which expand
to the numeric score, and explanatory data generated by Karmasphere
in the given context. For example, to generate a "traditional" karma
header for the connect context, use:

	add_header all Karma-Connect _KARMASCORE(connect)_: _KARMADATA(connect)_

Due to the limitations of SpamAssassin, it is impossible to generate
a header "X-Karma". The generated headers are all prefixed with
"X-Spam-". Post-filter programs designed to work with this Karma plugin
will therefore need to look for the configured header variants instead
of X-Karma.

=head1 INTERNALS

The plugin hooks two points in the SpamAssassin scanner cycle. It
sends Karmasphere queries during the parsed_metadata callback,
and it receives responses during the check_post_dnsbl callback.

Several hooks are provided for the user to alter the query packet
constructed. The routine which builds the packet by default calls
the following routines on itself to add fields to the query:

=over 4

=item $self->add_connect_authentication($scanner, $query)

Adds any information gathered from Authentication-Results headers
to the given connection query packet. This is usually authenticated
versions of of various identities checked by SPF, DKIM or other
external mechanisms.

=item $self->add_connect_received($scanner, $query)

Adds any information gathered from Received headers to the given
connection query packet. This frequently includes the client IP,
mail from address, and so forth.

=item $self->add_connect_envfrom($scanner, $query)

Adds the information gathered from $scanner->get('EnvelopeFrom:addr')
to the given connection query packet.

=item $self->add_connect_other($scanner, $query)

By default, this does nothing. This is the recommended extension
point for custom fields in the connection query packet.

=item $self->add_content_urls($scanner, $query)

Adds URLs found in the body to the given content query packet.

=item $self->add_content_other($scanner, $query)

By default, this does nothing. This is the recommended extension
point for custom fields in the content query packet.

=back

The plugin is designed to be subclassed by modulesoverriding the
add_*_other() routines. If you do this, you must load your subclass
instead of this class in your configuration file.

If SpamAssassin's debugging for the 'karma' facility is enabled
(i.e. would_log('dbg', 'karma') returns true), then access to the
L<Mail::Karmasphere::Client> Debug mechanism is provided via a
global variable $Mail::SpamAssassin::Plugin::Karmasphere::DEBUG. If
that variable contains a subroutine reference, the referenced
subroutine will be called as the L<Mail::Karmasphere::Client>
Debug routine.

Developers needing more information about any of the above features
should dig into the source code.

=head1 BUGS

Ensure that Authentication-Results headers are only honoured when
not preceded by a Received line.

=head1 TODO

Use the data fields from the Karma response to construct an
explanation message.

=head1 SEE ALSO

L<Mail::Karmasphere::Client>,
http://www.karmasphere.com/,
L<Mail::SpamAssassin>,
L<Mail::SpamAssassin::Conf>,
L<Mail::SpamAssassin::Logger>,
L<eg/spamassassin/26_karmasphere.cf>

=head1 COPYRIGHT

Copyright (c) 2005-2006 Shevek, Karmasphere. All rights reserved.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
