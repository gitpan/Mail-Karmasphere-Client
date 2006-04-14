use strict;
use warnings;
use blib;
use Test::More;

eval {
	require Mail::SpamAssassin::Plugin;
};

if ($@) {
	plan skip_all => "Could not load Mail::SpamAssassin::Plugin";
}
else {
	plan tests => 1;
}

use_ok('Mail::SpamAssassin::Plugin::Karmasphere');
