package Mail::Karmasphere::Parser::Base;

use strict;
use warnings;
use Data::Dumper;
use Mail::Karmasphere::Parser::Record;

sub new {
	my $class = shift;
	my $self = ($#_ == 0) ? { %{ (shift) } } : { @_ };
	die "No input mechanism (fh)" unless exists $self->{fh};
	die "No stream metadata (Streams)" unless exists $self->{Streams};
	return bless $self, $class;
}

sub warning {
	my $self = shift;
	if (++$self->{Warnings} < 10) {
		warn @_;
	}
}

sub error {
	my $self = shift;
	++$self->{Errors};
	die @_;
}

sub fh {
	return $_[0]->{fh};
}

sub _parse {
	die "Subclass must implement _parse routine";
}

sub streams {
	return $_[0]->{Streams};
}

sub parse {
	my $self = shift;
	return undef if $self->{Done};
	RECORD: for (;;) {
		my $record = $self->_parse;
		last RECORD unless defined $record;
		print Dumper($record) if $self->debug;
		my $stream = $record->stream;
		my $type = $self->{Streams}->[$stream];

		if (!defined $type) {
			$self->warning("Ignoring record: " .
							"Invalid stream: " .
							$stream);
			next RECORD;
		}
		elsif ($type ne $record->type) {
			$self->warning("Ignoring record: " .
							"Stream type mismatch: " .
							"Expected $type, got " . $record->type .
							": " . $record->as_string);
			next RECORD;
		}
		else {
			return $record;
		}
	}
	$self->{Done} = 1;
	return undef;
}

sub debug { $ENV{DEBUG} }

1;
