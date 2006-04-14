
package Mail::SpamAssassin::Plugin::Karmasphere;

use strict;
use warnings;
use vars qw(@ISA);
use bytes;
use Data::Dumper;
use Mail::Field;
use Mail::SpamAssassin::Plugin;
use Mail::Karmasphere::Client qw(:ALL);

@ISA = qw(Mail::SpamAssassin::Plugin);

# constructor: register the eval rule and parse any config
sub new {
  my $class = shift;
  my $mailsaobject = shift;

  # standard stuff here
  $class = ref($class) || $class;
  my $self = $class->SUPER::new($mailsaobject);
  bless ($self, $class);

  my $conf = $mailsaobject->{conf};

  #$self->register_eval_rule ("check_against_karma_db");
  $self->register_eval_rule ("karma_pass");
  $self->register_eval_rule ("karma_fail");

  $self->set_config($mailsaobject->{conf});

  return $self;
}

###########################################################################

sub set_config {
  my($self, $conf) = @_;
  my @cmds = ();


  push (@cmds, {
    setting => 'karma_good',
    default => 300,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
  });

  push (@cmds, {
    setting => 'karma_bad',
    default => -300,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
  });

  push (@cmds, {
      setting => 'karma_db_port',
      default => '8666',
      type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
  });

  push (@cmds, {
      setting => 'karma_db_host',
      default => 'slave.karmasphere.com',
      type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
  });

  push (@cmds, {
      setting => 'karma_feedlist',
      default => '0,1,2,3',
      type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
  });

  $conf->{parser}->register_commands(\@cmds);
}

# KS-specific functions below here
sub karma_pass {
    my ($self, $scanner) = @_;
    return 0 if $scanner->{local_test_only};
    my $result = $self->_get_karma_result($scanner) ;
    if ($result->value() >= $scanner->{conf}{karma_good} ) {
		return 1;
    } 
    else {
		return 0;
    }
}

sub karma_fail {
    my ($self, $scanner) = @_;    
    return 0 if $scanner->{local_test_only};
    my $result = $self->_get_karma_result ($scanner) ;
    if ($result->value() < $scanner->{conf}{karma_bad} ) {
	return 1;
    } 
    else {
	return 0;
    }
}

sub _get_karma_result {
  my ($self, $scanner) = @_;
  my $host = $scanner->{conf}{karma_db_host};
  my $port = $scanner->{conf}{karma_db_port};
  my $composite = $scanner->{conf}{karma_composite};

  my $data;
  my @identities;
  my @feedlist;

  my $received ;
  my @result;
  my %parse_tree;



  for ($scanner->{msg}->get_all_headers()) {
      # the SA module guarantees that SpamAssassin::Message::Node::get_all_headers()
      # returns the headers in the order they existed in the message
      # We therefore bail out after finding the first Received line, as that's the
      # only one we can trust and are interested in
      if (/^Received:\s+(.*?)\n/i) {
	  $received = Mail::Field->new('Received', $1);
	  last;
      }
  }

  if ( $received->parsed_ok() ) {
      %parse_tree = %{$received->parse_tree()};

      if (exists $parse_tree{from}{domain}) {
	  $data = [$parse_tree{from}{domain},IDT_DOMAIN_NAME ] ;
	  push @identities, $data;
      }
      if (exists $parse_tree{from}{HELO}) {
	  $data = [$parse_tree{from}{HELO},IDT_DOMAIN_NAME ] ;
	  push @identities, $data;
      }
      if (exists $parse_tree{from}{from}) {
	  $data = [$parse_tree{from}{from},IDT_DOMAIN_NAME ] ;
	  push @identities, $data;
      }
      if (exists $parse_tree{from}{address}) {
	  $data = [$parse_tree{from}{address},IDT_IP4_ADDRESS ] ;
	  push @identities, $data;
      }
      if (exists $parse_tree{for}{for}) {
	  $data = [$parse_tree{for}{for},IDT_EMAIL_ADDRESS ] ;
	  push @identities, $data;
      }            
  }

  my $client = new Mail::Karmasphere::Client (
					      PeerHost => $host,
					      PeerPort => $port,
					      );
  
  return $client->query(
  		Identities	=> \@identities,
		Composite	=> $composite,
			);
}


#########################################################################

1;

=head1 NAME

Mail::SpamAssassin::Plugin::Karmasphere - Query a Karmasphere reputation database

=head1 SYNOPSIS

  loadplugin     Mail::SpamAssassin::Plugin::Karmasphere
  header	 KARMASPHERE_TEST

=head1 DESCRIPTION

This plugin compares a message to the records published in a KS database to 
aid with spam classification

=head1 TODO

Check that when using spam[cd], data IS NOT preserved between messages

Check that data IS preserved between calls to different tests for the same message


=cut


=head1 USER SETTINGS

=over 4

=item B<karma_good>

Threshold for the aggregate score over which karma_pass() returns (1, reason)

=item B<karma_bad>

Threshold for the aggregate score below which karma_fail() returns (1, reason)

=item B<karma_db>

Hostname/IP address of the KS reputation database.  Defaults to C<slave.karmasphere.com>.

=item B<karma_port>

Port number of the KS reputation database.  Defaults to C<8666>.

=item B<karma_feedlist>

A CVS list of feeds to search.  Defaults to C<0,1,2,3>.

=cut


