#!/usr/bin/env bash
# progress_trees.sh — run a command and log its std.Progress node trees, even
# with no TTY (CI, a pipe, this sandbox). Useful for eyeballing progress output
# while developing it, since the live TUI erases itself and never renders off a
# terminal.
#
#   usage: tools/progress_trees.sh [--all] -- <command> [args...]
#     --all   print every frame (default: only frames that changed)
#
#   e.g. tools/progress_trees.sh -- \
#          zig-out/bin/fix build --progress=always ./foo.nix --no-link
#
# How it works: when ZIG_PROGRESS=<fd> is set, std.Progress skips the isatty
# check and instead writes a serialized node tree to <fd> on every refresh. We
# point that fd at a temp file, run the command, then decode the concatenated
# snapshots. Wire format (little-endian, see std/Progress.zig writeIpc):
#   per frame: [u8 N][N * Storage][N * u8 parent]
#   Storage (128 bytes): completed:u32, estimated_total:u32, name:[120]u8 (NUL-term)
#   parent byte: 0xFF root, 0xFE unused, else index into this frame's node array.
# Remember to pass the program's own progress flag (e.g. --progress=always) —
# ZIG_PROGRESS only changes the transport, not whether the program starts a
# progress session.
set -euo pipefail

show_all=0
if [[ "${1:-}" == "--all" ]]; then show_all=1; shift; fi
if [[ "${1:-}" == "--" ]]; then shift; fi
if [[ $# -eq 0 ]]; then
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

cap="$(mktemp)"
trap 'rm -f "$cap"' EXIT

# fd 3 -> capture file; the child inherits it and std.Progress writes there.
ZIG_PROGRESS=3 "$@" 3>"$cap" || true

SHOW_ALL="$show_all" perl -e '
  local $/; open my $fh, "<:raw", $ARGV[0] or die $!; my $buf = <$fh>;
  my $len = length $buf; my $p = 0; my $frame = 0; my $prev = "";
  while ($p < $len) {
    my $n = unpack("C", substr($buf, $p, 1)); $p += 1;
    my $need = $n * 128 + $n;
    last if $p + $need > $len;                       # truncated trailing frame
    my @nm; my @cc; my @tt; my @par;
    for my $i (0 .. $n - 1) {
      my $o = $p + $i * 128;
      my ($c, $t) = unpack("V V", substr($buf, $o, 8));
      my $raw = substr($buf, $o + 8, 120);
      $raw =~ s/\0.*$//s;                            # NUL-terminated
      $raw =~ s/[^[:print:]]//g;
      push @cc, $c; push @tt, $t; push @nm, $raw;
    }
    @par = unpack("C*", substr($buf, $p + $n * 128, $n));
    $p += $need; $frame++;

    # Render each node at its depth (walk parent chain; 0xFF = root/top).
    my $out = "";
    for my $i (0 .. $n - 1) {
      my $depth = 0; my $j = $par[$i]; my %seen;
      while (defined $j && $j != 0xFF && $j != 0xFE && !$seen{$j}++) {
        $depth++; $j = $par[$j];
      }
      my $label = $nm[$i]; $label = "(unnamed)" if $label eq "";
      my $cnt = "";
      $cnt = " [$cc[$i]/$tt[$i]]" if $tt[$i] != 0 && $tt[$i] != 0xFFFFFFFF;
      $cnt = " [$cc[$i]]"        if $tt[$i] != 0xFFFFFFFF && $tt[$i] == 0 && $cc[$i] != 0;
      $out .= ("  " x $depth) . "- " . $label . $cnt . "\n";
    }
    next if !$ENV{SHOW_ALL} && $out eq $prev;         # dedup unchanged frames
    $prev = $out;
    print "── frame $frame (" . $n . " nodes) " . ("─" x 20) . "\n";
    print $out eq "" ? "  (empty)\n" : $out;
  }
  print "(no progress frames captured — did the command start a progress session? pass --progress=always)\n" if $frame == 0;
' "$cap"
