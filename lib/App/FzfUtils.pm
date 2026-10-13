package App::FzfUtils;

use 5.010001;
use strict;
use warnings;
use Log::ger;

# AUTHORITY
# DATE
# DIST
# VERSION

our %SPEC;

our %argspecsopt_fzf = (
    no_hscroll => {
        summary => 'Will pass --no-hscroll to fzf',
        schema => 'true*',
    },
);

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Utilities related to fzf',
};

$SPEC{fzf2clip} = {
    v => 1.1,
    summary => "Select using fzf, then add selection to clipboard",
    description => <<'MARKDOWN',

This is basically a shortcut for:

    % fzf < input.txt | clipadd

where <prog:clipadd> is a utility from <pm:App::ClipboardUtils>.

MARKDOWN
    args => {
        input => {
            schema => 'str*',
            cmdline_src => 'stdin_or_files',
            pos => 0,
        },
        tee => {
            summary => 'In addition to adding to clipboard, also print to STDOUT',
            schema => 'bool*',
            cmdline_aliases => {t=>{}},
        },
    },
    deps => {
        all => [
            {prog => 'fzf'},
            #{prog => 'clipadd'},
        ],
    },
};
sub fzf2clip {
    require IPC::Open2;
    require Clipboard::Any;

    my %args = @_;

    my $input = $args{input};

    my $pid = IPC::Open2::open2(my $out, my $in, "fzf");
    for my $line (split /^/m, $input) {
        print $in $line;
    }
    close $in;
    my $result;
    {
        local $/;
        $result = <$out>;
        chomp($result) if defined $result;
    }
    close $out;
    waitpid($pid, 0);

  ADD_CLIPBOARD: {
        my $res = Clipboard::Any::add_clipboard_content(content => $result);
        return [500, "Can't add to clipboard: $res->[0] - $res->[1]"]
            unless $res->[0] == 200;
    }

    [200, "OK", $args{tee} ? $result : ""];
}

$SPEC{fzf2clip_loop} = {
    v => 1.1,
    summary => "Like fzf2clip, but loop/repeat",
    description => <<'MARKDOWN',

This is basically a shortcut for:

    % fzf --bind 'enter:execute(clipadd {})' < input.txt

where <prog:clipadd> is a utility from <pm:App::ClipboardUtils>.

MARKDOWN
    args => {
        input => {
            schema => 'str*',
            cmdline_src => 'stdin_or_files',
            pos => 0,
        },
    },
    deps => {
        all => [
            {prog => 'fzf'},
            {prog => 'clipadd'},
        ],
    },
};
sub fzf2clip_loop {
    require IPC::Open2;
    require Clipboard::Any;

    my %args = @_;

    my $input = $args{input};

    my $pid = IPC::Open2::open2(my $out, my $in, q[fzf --bind 'enter:execute-silent(clipadd {})']);
    for my $line (split /^/m, $input) {
        print $in $line;
    }
    close $in;
    close $out;
    waitpid($pid, 0);

    [200, "OK"];
}

sub _gen_cs_select_html {
    my $dict = shift;

    require JSON::PP;

    # Do not interpolate the data directly into Javascript.  Apart from quoting
    # problems, a line containing "</script>" would otherwise terminate the
    # script element.  JSON escapes are understood by JSON.parse after the text
    # has been read from this non-executable element.
    my @ids = sort {
        $a =~ /\A\d+\z/ && $b =~ /\A\d+\z/ ? $a <=> $b : $a cmp $b
    } keys %$dict;
    my @items = map {
        +{id => $_, line => $dict->{$_}{line},
          clip_content => $dict->{$_}{clip_content}}
    } @ids;
    my $json = JSON::PP->new->canonical->encode(\@items);
    $json =~ s/&/\\u0026/g;
    $json =~ s/</\\u003c/g;
    $json =~ s/>/\\u003e/g;
    $json =~ s/\x{2028}/\\u2028/g;
    $json =~ s/\x{2029}/\\u2029/g;

    my $html = <<'HTML';
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cs-select</title>
<style>
:root { color-scheme: light dark; font-family: ui-monospace, SFMono-Regular, Consolas, monospace }
* { box-sizing: border-box }
body { margin: 0; background: Canvas; color: CanvasText }
#search { position: sticky; top: 0; width: 100%; padding: .75rem 1rem; border: 0;
  border-bottom: 1px solid GrayText; outline: 0; font: inherit; background: Canvas }
#status { padding: .35rem 1rem; color: GrayText; font-size: .85rem }
#matches { margin: 0; padding: 0; list-style: none }
#matches li { padding: .4rem 1rem; white-space: pre-wrap; overflow-wrap: anywhere; cursor: default }
#matches li.selected { color: HighlightText; background: Highlight }
#empty { padding: .75rem 1rem; color: GrayText }
</style>
</head>
<body>
<input id="search" type="text" autocomplete="off" spellcheck="false"
       aria-label="Search" placeholder="Type to search; Enter copies; Up/Down selects">
<div id="status" role="status" aria-live="polite"></div>
<ul id="matches" role="listbox"></ul>
<script id="cs-items" type="application/json">__CS_ITEMS__</script>
<script>
(() => {
  'use strict';
  const items = JSON.parse(document.getElementById('cs-items').textContent);
  const input = document.getElementById('search');
  const list = document.getElementById('matches');
  const status = document.getElementById('status');
  let matches = [];
  let selected = 0;

  // A compact fzf-like ranker: every query character must occur in order.
  // Consecutive characters and word/camel-case starts receive large bonuses;
  // gaps and late starts are penalized. Whitespace-separated terms are ANDed.
  function termScore(text, term, caseSensitive) {
    const haystack = caseSensitive ? text : text.toLowerCase();
    const needle = caseSensitive ? term : term.toLowerCase();
    if (!needle.length) return 0;
    let previous = new Map();
    for (let qi = 0; qi < needle.length; qi++) {
      const current = new Map();
      for (let ti = 0; ti < haystack.length; ti++) {
        if (haystack[ti] !== needle[qi]) continue;
        const before = ti ? text[ti - 1] : '';
        const here = text[ti];
        const boundary = ti === 0 || /[\s_\-\/.:[\]()]/.test(before);
        const camel = /[a-z]/.test(before) && /[A-Z]/.test(here);
        const base = 10 + (boundary ? 18 : 0) + (camel ? 14 : 0);
        if (qi === 0) {
          current.set(ti, base - ti);
        } else {
          let best = -Infinity;
          for (const [pi, score] of previous) {
            if (pi >= ti) continue;
            const gap = ti - pi - 1;
            best = Math.max(best, score + base + (gap === 0 ? 24 : -gap));
          }
          if (best > -Infinity) current.set(ti, best);
        }
      }
      if (!current.size) return null;
      previous = current;
    }
    return Math.max(...previous.values());
  }

  function score(text, query) {
    const terms = query.trim().split(/\s+/).filter(Boolean);
    if (!terms.length) return 0;
    let total = 0;
    for (const term of terms) {
      const part = termScore(text, term, /[A-Z]/.test(term));
      if (part === null) return null;
      total += part;
    }
    return total;
  }

  function render() {
    const query = input.value;
    matches = items.map((item, order) => ({item, order, score: score(item.line, query)}))
      .filter(match => match.score !== null)
      .sort((a, b) => b.score - a.score || a.order - b.order);
    selected = Math.min(selected, Math.max(0, matches.length - 1));
    list.replaceChildren();
    for (let i = 0; i < matches.length; i++) {
      const li = document.createElement('li');
      li.textContent = matches[i].item.line;
      li.setAttribute('role', 'option');
      li.setAttribute('aria-selected', i === selected ? 'true' : 'false');
      if (i === selected) li.className = 'selected';
      li.addEventListener('mousedown', event => {
        event.preventDefault();
        selected = i;
        paintSelection();
      });
      list.appendChild(li);
    }
    status.textContent = matches.length ? `${matches.length} match${matches.length === 1 ? '' : 'es'}` : 'No matches';
  }

  function paintSelection() {
    [...list.children].forEach((row, i) => {
      row.classList.toggle('selected', i === selected);
      row.setAttribute('aria-selected', i === selected ? 'true' : 'false');
    });
    list.children[selected]?.scrollIntoView({block: 'nearest'});
  }

  async function copySelected() {
    if (!matches.length) return;
    const content = matches[selected].item.clip_content;
    try {
      if (!navigator.clipboard || !window.isSecureContext) throw new Error('clipboard unavailable');
      await navigator.clipboard.writeText(content);
    } catch (_) {
      const area = document.createElement('textarea');
      area.value = content;
      area.style.cssText = 'position:fixed;left:-9999px;top:0';
      document.body.appendChild(area);
      area.select();
      if (!document.execCommand('copy')) {
        area.remove();
        status.textContent = 'Could not copy to clipboard';
        input.focus();
        return;
      }
      area.remove();
    }
    status.textContent = 'Copied to clipboard';
    input.focus();
  }

  input.addEventListener('input', () => { selected = 0; render() });
  input.addEventListener('keydown', event => {
    if (event.key === 'ArrowDown' && matches.length) {
      event.preventDefault(); selected = Math.min(selected + 1, matches.length - 1); paintSelection();
    } else if (event.key === 'ArrowUp' && matches.length) {
      event.preventDefault(); selected = Math.max(selected - 1, 0); paintSelection();
    } else if (event.key === 'Enter') {
      event.preventDefault(); copySelected();
    } else if (event.key === 'Escape') {
      input.value = ''; selected = 0; render();
    }
  });

  render();
  input.focus();
})();
</script>
</body>
</html>
HTML
    $html =~ s/__CS_ITEMS__/$json/;
    return $html;
}

$SPEC{cs_select} = {
    v => 1.1,
    summary => "Select entries from template to clipboard",
    description => <<'MARKDOWN',

This is basically similar to:

    % fzf --bind 'enter:execute(clipadd {})' < template.txt

except that it does some pre-processing to let each template entry be a
multiple-line text, and later do post-processing so the original entry is added
to the clipboard.

**Template format**

Template is an Org file with a particular format, where each entry is put under
a level-2 heading. The level-1 heading can be used for grouping/categorizing.
For example:

    * Product > P1
    ** Does P1 need to be replaced every 5 years?  :replacement:clipadd_1:
    Yes, ideally every 3-5 years.
    ** How to maintain P1 so it is in a good condition and can last longer?
    Wash after every use, then dry.
    Keep it clean.
    And of course replace after 3-5 years.
    * Product > P2
    ** Entry 1  :clipadd_2:
    ...
    ** Entry 2
    ...
    * General > Support
    ** Entry 3
    ...
    ** Entry 4
    ...

Before feeding to `fzf`, this utility will convert each entry into a single
line:

    [id=1][title=Does P1 need to be replaced every 5 years?]Yes, ideally every 3-5 years.[category=Product > P1][tag=replacement][tag=clipadd_1]
    [id=2][title=How to maintain P1 so it is in a good condition and can last longer?]Wash after every use, then dry. Keep it clean. And of course replace after 3-5 years.[category=Product > P1]
    [id=3][title=Entry 1]...[tag=clipadd_2][category=Product > P2]
    [id=4][title=Entry 2]...[category=Product > P2]
    [id=5][title=Entry 3]...[category=General > Support]
    [id=6][title=Entry 4]...[category=General > Support]

after selection, another script (<prog:cs-select-helper>) will turn back the
single-line entry into the original.

**Tags**

Some Org tags are used to customize how the entry is displayed or copied to
clipboard.

**no_copy_title**. Do not copy the title to clipboard, only the content.

**exclude**. Do not include this entry (or any child entries).

MARKDOWN
    args => {
        template => {
            schema => 'str*',
            cmdline_src => 'stdin_or_files',
            pos => 0,
        },
        wrap => {
            schema => 'posint*',
            cmdline_aliases => {w=>{}},
        },
        %argspecsopt_fzf,
        gen_json => {
            summary => 'Instead of running fzf, generate the raw JSON file then exit',
            schema => 'true*',
        },
        gen_html => {
            summary => 'Instead of running fzf, generate the HTML (which lets user selects the items via browser), then exit',
            schema => 'true*',
        },
    },
    args_rels => {
        choose_one => [qw/gen_json gen_html/],
    },
    deps => {
        all => [
            {prog => 'fzf'},
            {prog => 'clipadd'},
        ],
    },
};
sub cs_select {
    require Clipboard::Any;
    require File::Temp;
    require IPC::Open2;
    require JSON::PP;
    require Org::Parser::Tiny;
    require Text::ANSI::Util;

    my %args = @_;

    my $template = $args{template};
    my $doc = Org::Parser::Tiny->new->parse($template);

    my @lines;
    my $jsonfile;
  PREPROCESS_TEMPLATE: {
        my $dict = {};
        my $id = 0;
        for my $h1 (grep { $_->isa("Org::Parser::Tiny::Node::Headline") && $_->level == 1 } @{ $doc->children }) {
            my $category = $h1->title;
            my @h1_tags = @{ $h1->tags };
            for my $h2 (grep { $_->isa("Org::Parser::Tiny::Node::Headline") && $_->level == 2 } @{ $h1->children }) {
                $id++;
                my $title = $h2->title;
                my $content = $h2->as_string;
                my @h2_tags = @{ $h2->tags };

                my $exclude = (grep {$_ eq 'exclude'} @h1_tags, @h2_tags);
                next if $exclude;

                $content =~ s/\A.+\R//; # dump the raw heading

                my $no_copy_title = (grep {$_ eq 'no_copy_title'} @h1_tags, @h2_tags);

                my $clip_content;
                my $clip_title = ($no_copy_title ? "" : $title . ":\n");
                if ($args{wrap}) {
                    $clip_content = $clip_title . Text::ANSI::Util::ta_wrap($content, $args{wrap});
                } else {
                    $clip_content = $clip_title . $content;
                }

                (my $line_content = $content) =~ s/\R+/ /g;
                my $line = join(
                    "",
                    "[id=$id][title=", $h2->title, "]",
                    $line_content,
                    "[category=$category]",
                );
                push @lines, "$line\n";
                $dict->{$id} = {clip_content=>$clip_content, line=>$line};
            }
        }

        if ($args{gen_json}) {
            return [200, "OK", JSON::PP::encode_json($dict)];
        }
        if ($args{gen_html}) {
            return [200, "OK", _gen_cs_select_html($dict)];
        }

        (my $tempfh, $jsonfile) = File::Temp::tempfile('XXXXXXXX', TMPDIR=>1, SUFFIX=>'.json');
        log_trace "JSON file is at %s", $jsonfile;
        print $tempfh JSON::PP::encode_json($dict);
        close $tempfh;
    } # PREPROCESS_TEMPLATE

    my @fzf_opts;
    if ($args{no_hscroll}) {
        push @fzf_opts, "--no-hscroll";
    }
    my $fzf_opts = join(" ", @fzf_opts);

    my $pid = IPC::Open2::open2(my $out, my $in, qq[fzf $fzf_opts --bind 'enter:execute-silent(cs-select-helper $jsonfile {})']);
    for my $line (@lines) {
        print $in $line;
    }
    close $in;
    close $out;
    waitpid($pid, 0);

    [200, "OK"];
}

1;
# ABSTRACT:

=head1 DESCRIPTION

This distribution includes the following CLI utilities related to fzf:

# INSERT_EXECS_LIST
