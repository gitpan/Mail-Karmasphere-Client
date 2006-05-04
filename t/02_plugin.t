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
	plan tests => 5;
}

use_ok('Mail::SpamAssassin::Plugin::Karmasphere');

use_ok('Mail::SpamAssassin');
use_ok('Mail::SpamAssassin::Conf');
use_ok('Mail::SpamAssassin::PerMsgStatus');

my $main = new Mail::SpamAssassin({
				config_text => <<'EOR',
loadplugin Mail::SpamAssassin::Plugin::Karmasphere

karma	KARMA_CONNECT_0_10	connect 0 10
EOR
				debug		=> 'all',
					});
is($main->lint_rules(), 0, 'SpamAssassin lint succeeded');

# my $mail = $main->parse('');
# $main->check($mail);
