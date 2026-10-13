use 5.010001;
use strict;
use warnings;
use Test::More;
use JSON::PP;

use lib 'lib';
use App::FzfUtils;

my $html = App::FzfUtils::_gen_cs_select_html({
    20 => {line => 'beta', clip_content => "copy beta\n"},
    3  => {
        line => '</script><b>alpha & friends</b>',
        clip_content => "alpha \x{263a}\n",
    },
});

like($html, qr/\A<!doctype html>/, 'returns a complete HTML document');
like($html, qr/addEventListener\('input'/, 'search updates on input');
like($html, qr/event\.key === 'Enter'/, 'Enter copies the selection');
like($html, qr/function termScore/, 'contains the fuzzy scorer');
unlike($html, qr{</script><b>}, 'HTML-like item text cannot end the data script');

my ($json) = $html =~ m{<script id="cs-items" type="application/json">(.*?)</script>}s;
ok(defined $json, 'contains an application/json data element');
my $items = JSON::PP->new->decode($json);
is_deeply(
    $items,
    [
        {id => 3, line => '</script><b>alpha & friends</b>', clip_content => "alpha \x{263a}\n"},
        {id => 20, line => 'beta', clip_content => "copy beta\n"},
    ],
    'item data round-trips and numeric IDs retain their order',
);

done_testing;
