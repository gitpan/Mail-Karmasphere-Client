use strict;
use warnings;
use blib;
use Carp qw(cluck);

use Test::More tests => 8;

use_ok('Mail::Karmasphere::Client');
use_ok('Mail::Karmasphere::Query');
use_ok('Mail::Karmasphere::Response');

local $SIG{__WARN__} = sub { cluck @_; };

my $client = new Mail::Karmasphere::Client();
for (0..4) {
	my $query = new Mail::Karmasphere::Query();
	$client->send($query);
}
for (0..4) {
	my $response = $client->recv();
	ok(defined $response, "Got a response without giving an id");
}
