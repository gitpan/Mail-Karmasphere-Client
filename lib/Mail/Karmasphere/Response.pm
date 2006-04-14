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
	return $self->{_};
}

sub time {
	return $_[0]->{'time'};
}

sub facts {
	my $self = shift;
	return $self->{f} if exists $self->{f};
	return $self->{facts} if exists $self->{facts};
	return [];
}

sub combinations {
	my $self = shift;
	return $self->{c} if exists $self->{c};
	return $self->{combiners};
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
	my $out = "Response id '$self->{_}': ";
	$out = $out . $self->time . "ms, ";
	my @names = $self->combiner_names;
	$out = $out . scalar(@names) . " combinations, ";
	$out = $out . scalar(@{ $self->facts }) . " facts\n";
	if ($self->error) {
		$out .= "Error " . $self->message . "\n";
	}
	else {
		foreach (@names) {
			my $value = $self->value($_);
			my $data = $self->data($_) || '(undef)';
			$out .= "Combiner '$_': verdict $value ($data)\n";
		}
		foreach (@{$self->facts}) {
			$out .= "Feed '$_->{f}' opinion $_->{v} ($_->{d})\n";
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
Response and the Client. The user constructs a Query, passes it to
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

=cut

1;
