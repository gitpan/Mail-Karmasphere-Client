package Mail::Karmasphere::Response;

use strict;
use warnings;
use Exporter;

sub new {
	my $class = shift;
	my $self = ($#_ == 0) ? { %{ (shift) } } : { @_ };
	return bless $self, $class;
}

sub id {
	my ($self) = @_;
	$self->{_} = '???' unless defined $self->{_};
	return $self->{_};
}

sub time {
	my $self = shift;
	return $self->{t} if defined $self->{t};
	return $self->{'time'} if defined $self->{'time'};
	return '???';
}

# deprecated
sub facts {
	my $self = shift;
	return $self->{f} if exists $self->{f};
	return $self->{facts} if exists $self->{facts};
	$self->{f} = [];
	return $self->{f};
}

sub attributes {
	my $self = shift;
	return $self->{f} if exists $self->{f};
	return $self->{facts} if exists $self->{facts};
	$self->{f} = [];
	return $self->{f};
}

sub combinations {
	my $self = shift;
	return $self->{c} if exists $self->{c};
	return $self->{combiners} if exists $self->{combiners};
	$self->{c} = {};
	return $self->{c};
}

sub combination {
	my ($self, $combiner) = @_;
	return () unless $self->combinations;
	return $self->combinations->{$combiner};
}

sub combiner_names {
	my ($self) = @_;
	return () unless $self->combinations;
	return keys %{ $self->combinations };
}

sub _combination_get {
	my ($self, $key, $combiner) = @_;
	return undef unless $self->combinations;
	if ($combiner) {
		my $combination = $self->combination($combiner);
		return undef unless $combination;
		return $combination->{$key};
	}
	my $combination = $self->combination('default');
	if ($combination) {
		return $combination->{$key};
	}
	foreach (values %{ $self->combinations }) {
		return $_->{$key} if exists $_->{$key};
	}
	return undef;
}

sub value {
	my $self = shift;
	return $self->_combination_get('v', @_);
}

sub data {
	my $self = shift;
	return $self->_combination_get('d', @_);
}

sub error {
	return $_[0]->{error};
}

sub message {
	return $_[0]->{message};
}

sub as_string {
	my ($self) = @_;
	my $out = "Response id '" . $self->id . "': ";
	$out = $out . $self->time . "ms, ";
	my @names = $self->combiner_names;
	$out = $out . scalar(@names) . " verdicts, ";
	$out = $out . scalar(@{ $self->facts }) . " attributes\n";
	if ($self->error) {
		$out .= "Error: " . $self->message . "\n";
	}
	else {
		if ($self->message) {
			$out .= "Warning: " . $self->message . "\n";
		}
		foreach (sort @names) {
			my $value = $self->value($_);
			my $data = $self->data($_);
			$value = 0 unless defined $value;	# Might happen
			$data = '(undef)' unless defined $data;
			$out .= "Combiner '$_': verdict $value ($data)\n";
		}
		my @facts = sort { $a->{f} cmp $b->{f} } @{$self->facts};
		foreach (@facts) {
			my $d = $_->{d};
			$d = "null data" unless defined $d;
			$out .= "Attribute '$_->{f}':";
			$out .= " identity '$_->{i}'" if exists $_->{i};
			$out .= " value $_->{v} ($d)\n";
		}
	}
	return $out;
}

=head1 NAME

Mail::Karmasphere::Response - Karmasphere Response Object

=head1 SYNOPSIS

	See Mail::Karmasphere::Client

=head1 DESCRIPTION

The Perl Karma Client API consists of three objects: The Query, the
Response and the Client. The user constructs a Query and passes it to
a Client, which returns a Response. See L<Mail::Karmasphere::Client>
for more information.

=head1 METHODS

=over 4

=item $response->facts()

Returns a list of fact data.

=item $response->combination($name)

Returns the named combination as a hash reference.

=item $response->value($name)

Returns the value of the named combination.

If no combiner name is given, this method looks for a combination
called 'default', if present, otherwise searches for the first
available combination with a value.

If $name is given, this is equivalent (but preferable) to
$response->combination($name)->{v}.

=item $response->data($name)

Returns the data of the named combination.

The rules for choosing a combination are the same as those for
$response->value($name).

=item $response->id()

Returns the id of this response. It will match the id passed in the
query, which was either specified by the user or generated by the
client.

=item $response->time()

Returns the time in milliseconds taken by this request.

=back

=head1 BUGS

This document is incomplete.

=head1 SEE ALSO

L<Mail::Karmasphere::Client>
L<Mail::Karmasphere::Query>
http://www.karmasphere.com/

=head1 COPYRIGHT

Copyright (c) 2005 Shevek, Karmasphere. All rights reserved.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
