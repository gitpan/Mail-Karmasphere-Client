
package Mail::SpamAssassin::Plugin::Karmasphere;

use strict;
use warnings;
use vars qw(@ISA);
use bytes;
use Carp qw(confess);
use Time::HiRes;
use Mail::SpamAssassin::Plugin;
use Mail::SpamAssassin::Logger;
use Mail::Karmasphere::Client qw(:ALL);

@ISA = qw(Mail::SpamAssassin::Plugin);

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

	push (@cmds, {
		setting		=> 'karma_connect_feedset',
		default		=> 'karmasphere.emailchecker',
		type		=> $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	});

	push (@cmds, {
		setting		=> 'karma_content_feedset',
		default		=> 'karmasphere.contentfilter',
		type		=> $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
	});

	push (@cmds, {
		setting		=> 'karma',
		code		=> sub {
			my ($self, $key, $value, $line) = @_;
			if ($value =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/) {
				my ($rulename, $context, $min, $max) =
								($1, $2, 0+$3, 0+$4);
				$self->{karma_rules}->{$rulename} =
								[ $context, $min, $max ];
				$self->{parser}->add_test($rulename,
						"check_karma_range('$context', $min, $max)",
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
		default		=> '60',
		is_admin	=> 1,
		type		=> $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
	});

	$conf->{parser}->register_commands(\@cmds);
}

sub _karma_client {
	my $self = shift;
	my $conf = shift || $self->{main}{conf};
	unless ($self->{Client}) {
		$self->{Client} = new Mail::Karmasphere::Client (
						# Debug	=> 1,
						PeerHost	=> $conf->{karma_host},
						PeerPort	=> $conf->{karma_port},
							);
	}
	return $self->{Client};
}

sub _karma_send {
	my ($self, $scanner) = @_;

	my $conf = $scanner->{conf};
	my $client = $self->_karma_client($conf);

	my $query_connect = new Mail::Karmasphere::Query();
	$query_connect->composite($conf->{karma_connect_feedset});

	# Now we have to navigate the twists and turns of the SpamAssassin
	# API to retrieve the message metadata we want. This is largely
	# inconsistent, and I hope it holds up.

	if ($scanner->{num_relays_untrusted} > 0) {
		my $lasthop = $scanner->{relays_untrusted}->[0];
		if (!defined $lasthop) {
			dbg("karma: message was delivered entirely via trusted relays, not required");
			return;
		}
		my $ip = $lasthop->{ip};
		$query_connect->identity($ip, IDT_IP4_ADDRESS);
		my $helo = $lasthop->{helo};
		$query_connect->identity($helo, IDT_DOMAIN_NAME);
	}

	my $envfrom = $scanner->get('EnvelopeFrom:addr');
	$query_connect->identity($envfrom, IDT_EMAIL_ADDRESS);

	my $id_connect = $client->send($query_connect);
	$scanner->{karma}->{id}->{connect} = $id_connect;


	my @uris = $scanner->get_uri_list();
	if (@uris) {
		my $query_content = new Mail::Karmasphere::Query();
		$query_content->composite($conf->{karma_content_feedset});
		for my $uri (@uris) {
			$query_content->identity($uri, IDT_URL);
		}
		my $id_content = $client->send($query_content);
		$scanner->{karma}->{id}->{content} = $id_content;
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
	dbg("_karma_recv: id_connect=$id_connect");
	my $response_connect = $client->recv($id_connect, $timeout);
	dbg("_karma_recv: response_connect=$response_connect");

	my $id_content = $scanner->{karma}->{id}->{content};
	my $response_content = undef;
	if ($id_content) {
		dbg("_karma_recv: id_content=$id_content");
		$response_content = $client->recv($id_content,
						$finish - time());
		dbg("_karma_recv: response_content=$response_content");
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

	return unless $conf->{karma_rules};

	my %rules = %{ $conf->{karma_rules} };
	while (my ($rulename, $data) = each(%rules)) {
		my ($context, $min, $max) = @$data;
		my $response = $responses->{$context};
		next unless $response;
		my $value = $response->value;
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

	karma KARMA_CONNECT_0_10	connect 0 10
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

=over 4

=item B<karma> I<context> I<min> I<max>

A karma score range. B<context> is either B<connect> or B<content>

=item B<karma_connect_feedset>

The feedset name to query using connect-time information.
The default is C<karmasphere.emailchecker>.

=item B<karma_content_feedset>

The feedset name to query using content information.
The default is C<karmasphere.contentfilter>.

=item B<karma> rulename context min max

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
The default is C<60>.

=back

=head1 INTERNALS

The plugin hooks two points in the SpamAssassin scanner cycle. It
sends Karmasphere queries during the parsed_metadata callback,
and it receives responses during the check_post_dnsbl callback.

Developers needing more information should dig into the source code.

=head1 BUGS

See L<TODO>.

=head1 TODO

Implement authentication.

=head1 SEE ALSO

L<Mail::Karmasphere::Client>
L<http://www.karmasphere.com/>
L<Mail::SpamAssassin>

=head1 COPYRIGHT

Copyright (c) 2005-2006 Shevek, Karmasphere. All rights reserved.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
