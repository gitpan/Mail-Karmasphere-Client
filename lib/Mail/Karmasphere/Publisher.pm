package Mail::Karmasphere::Publisher;

use strict;
use warnings;
use vars qw(@ISA @EXPORT_OK %EXPORT_TAGS);

use Exporter;
use Data::Dumper;
use Time::HiRes;
use File::Temp;
use IO::File;
use LWP::UserAgent;
use HTTP::Request::Common;

BEGIN {
	@ISA = qw(Exporter);
	@EXPORT_OK = qw();
	%EXPORT_TAGS = (
		'all' => \@EXPORT_OK,
		'ALL' => \@EXPORT_OK,
	);
}

sub new {
	my $class = shift;
	my $self = ($#_ == 0) ? { %{ (shift) } } : { @_ }; 
	# Check for Principal, Credentials
	return bless $self, $class; 
}

sub _output_file {
	my ($input, $output, $index) = @_;
	return $output if ref $output;	# An IO::File
	return new IO::File("> $output") if defined $output;
	my $temp = $input;
	return new File::Temp(
				TEMPLATE	=> "$input.$$.$index.XXXXXX",
				SUFFIX		=> ".ktmp",
					);
}

# Do not fuck with this method, Karma-Syndicator calls it.
sub parse {
	my ($self, $input, $class, $outputs, %args) = @_;

	eval qq{ require $class; };
	die $@ if $@;

	my $fh = new IO::File("< $input");
	my $parser = $class->new(fh => $fh, %args);
	my $streams = $parser->streams;

	$outputs ||= [];	# An array of filenames.

	# print STDERR "outputs are " . Dumper($outputs);
	my @files = map { _output_file($input, $outputs->[$_], $_) }
					(0..$#$streams);
	# print STDERR "files are " . Dumper(\@files);

	while (my @records = $parser->parse) {
		for my $record (@records) {
			next if not defined $record;
			my $file = $files[$record->stream];
			print $file $record->as_string, "\n";
		}
	}

	return 1;
}

sub publish {
    my ($self, $file, $class, $params) = @_;

    my $ua = LWP::UserAgent->new;

    my $url  = $params->{url};
    my $feed = $params->{feed};

    my $req = POST ($url,
		    Content_Type => "form-data",
		    Content => 
		    [ feed_id  => $feed,
		      login    => $params->{user},
		      password => $params->{pass},
		      data_source => "upload",
		      data_file => [ $file ],
		      ]);

    if (defined $params->{htuser}) {
	$req->headers->authorization_basic($params->{htuser},
					   $params->{htpass});
    }
    
    my $res = $ua->request($req);
	return $res;
}



1;

__END__

USE CASES

1. simple single format input

2. complex multiple format input

the parser splits the input file into multiple intermediate files.  one file per stream.

each intermediate file is then uploaded as a separate feed.


