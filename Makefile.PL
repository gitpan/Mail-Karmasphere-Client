use 5.006;
use ExtUtils::MakeMaker;

# Thanks to YAML
my @programs = ();
for (split "\n", <<'QUERIES') {
karmaclient|y|Karmasphere command line query client
karmad|y|Karmasphere postfix/exim daemon
QUERIES
	my ($program, $default, $description) = split /\|/, $_;
	if (prompt("Do you want to install '$program', the $description?", 
			   $default) =~ /^y/) {
		push(@programs, $program);
	}
}

WriteMakefile(
    'NAME'		=> 'Mail::Karmasphere::Client',
    'VERSION_FROM'	=> 'lib/Mail/Karmasphere/Client.pm',
    'PREREQ_PM'		=> {
				'Convert::Bencode'				=> 0,
				# 'Class::Accessor'				=> 0,
				'IO::Socket'					=> 0,
			},
	ABSTRACT_FROM => 'lib/Mail/Karmasphere/Client.pm',
	AUTHOR     => 'Shevek <cpan@anarres.org>',
	EXE_FILES	=> \@programs,
);

sub MY::postamble {
	my $self = shift;
	my $old = $self->MM::postamble(@_);
	chomp($old);
	my $new = <<'EON';

.PHONY : aux readme

aux : readme

readme : lib/Mail/Karmasphere/Client.pm
	perldoc -t lib/Mail/Karmasphere/Client.pm > README

EON
	return $old . $new;
}
