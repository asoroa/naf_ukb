#!/usr/bin/perl

use strict;

use XML::LibXML;
use File::Temp;
use File::Basename;
use IPC::Open3;
use IO::Select;
use Symbol;						# for gensym
use Sys::Hostname;
use FindBin qw($Bin);
use lib $Bin;
use Match;
use Data::Dumper;
use 5.010;

binmode STDOUT;

use Getopt::Std;

my %opts;

getopts('x:m:M:W:D:K:', \%opts);

my $wsd_exec = $opts{'x'} ? $opts{'x'} : "./ukb_wsd";
my $kb_binfile = $opts{'M'};
$kb_binfile = $opts{'K'} unless $kb_binfile;
my $dict_file = $opts{'W'};
$dict_file = $opts{'D'} unless $dict_file;

my $fname;

if (!@ARGV || $ARGV[0] eq "--") {
	$fname = "<-";
} else {
	$fname = shift;
}

&usage("Error: no dictionary") unless -f $dict_file;
&usage("Error: no KB graph") unless -f $kb_binfile;

my $kb_resource = basename($kb_binfile, '.bin');

my $UKB_VERSION = &try_wsd($wsd_exec);
&usage("Error: can't execute $wsd_exec") unless $UKB_VERSION;

# @@ By now, mw is done with --nopos

my $wsd_extraopts;
my $opt_nopos = 1;

if (@ARGV && $ARGV[0] eq "--") {
	shift @ARGV;
	$wsd_extraopts = join(" ", @ARGV);
}

my $wsd_cmd = " $wsd_exec -K $kb_binfile -D $dict_file --allranks $wsd_extraopts";

# default POS mapping for KAF

my %POS_MAP = ("^N.*" => 'n',
			   "^R.*" => 'n',
			   "^G.*" => 'a',
			   "^V.*" => 'v',
			   "^A.*" => 'r');

%POS_MAP = &read_pos_map( $opts{'m'} ) if $opts{'m'};

open(my $fh_fname, $fname);
binmode $fh_fname;

my $VOCAB = new Match($dict_file);

my $parser = XML::LibXML->new();
my $doc;

eval {
	$doc = $parser->parse_fh($fh_fname);
};
die $@ if $@;

my $root = $doc->getDocumentElement;

my $beg_tstamp = &get_datetime();

# $idRef -> array with sentence id's
# $docRef -> docs
# e.g.
# $idRef->[0] -> id of first setence
# $docRef->[0] firt sentence ([ { lema => lema, pos => pos, id => tid, spanid => [wid1, wid2] } ...])

my ($idRef, $docRef) = &getSentences($root);

my $Sents;    # [ ["lemma#pos#mid", "lemma#pos#mid" ...], ... ]
my $id2mark;  # { mid => mark_elem }

($Sents, $id2mark) = &create_markables_layer($doc, $idRef, $docRef);

# $doc->toFH(\*STDOUT, 1);
# die;

my @Ctxs;
my $ctx_size = &w_count($docRef);

die "Error: no sentences (have you mapped the POS values?)\n" unless $ctx_size;

$ctx_size = 20 if $ctx_size > 20; # contexts of max. 20 words

if (scalar(@{ $Sents }) > 1 ) {
	@Ctxs= &create_ctxs($Sents, $ctx_size);
} else {
	@Ctxs = &create_ctxs_nosentence($Sents->[0], $ctx_size);
	my @ids = map { $idRef->[0] } @Ctxs;
	$idRef = \@ids;
}

my %Sense_map = &wsd($wsd_cmd, \@Ctxs, $idRef);	# { tid => { sense => score } }

while (my ($mid, $h) = each %Sense_map) {
	next unless scalar keys %{ $h };
	my $mark_elem = $id2mark->{$mid};
	my $xrefs_elem = $doc->createElement('externalReferences');
	foreach my $sid (sort {$h->{$b} <=> $h->{$a}} keys %{ $h }) {
		my $xref_elem = $doc->createElement('externalRef');
		$xref_elem->setAttribute('resource', $kb_resource);
		$xref_elem->setAttribute('reference', $sid);
		$xref_elem->setAttribute('confidence', $h->{$sid} );
		$xrefs_elem->addChild($xref_elem);
	}
	$mark_elem->addChild($xrefs_elem);
}

&add_lp_header($doc, $beg_tstamp, &get_datetime());

$doc->toFH(\*STDOUT, 1);

sub wsd {

	my ($cmd, $ctxRef, $idRef) = @_;

	my $ftmp = File::Temp->new();
	die "Can't create temporal file:$!\n" unless $ftmp;
	binmode ($ftmp, ':utf8');

	for (my $i=0; $i < scalar @{ $ctxRef }; $i++) {
		print $ftmp $idRef->[$i]."\n";
		print $ftmp join(" ", @{ $ctxRef->[$i] })."\n";
	}
	$ftmp->close();

	my $otmp = File::Temp->new();
	$otmp->close();

	my $wsd_cmd = "$cmd $ftmp > $otmp 2> /dev/null";
	eval {
		system "$wsd_cmd";
	};

	if ($?) {
		$ftmp->unlink_on_destroy(0);
		die "Error when executing wsd command:\n$wsd_cmd\n";
	}

	open(my $fh, $otmp->filename) || die "Can't open $otmp->filename:$!\n";
	binmode ($fh, ':utf8');
	my %H;
	<$fh>;						# skip first line
	while (my $inst = <$fh>) {
		chomp ($inst);
		my ($sent, $tid, @sid) = split(/\s+/, $inst);
		pop @sid;				# lemma
		pop @sid;				# comment mark
		foreach my $item (@sid) {
			my ($sid, $w) = split(/\//, $item);
			$w = 1 unless $w;
			$H{$tid}->{$sid} = $w;
		}
	}
	return %H;
}

sub create_ctxs {

	my ($docRef, $size) = @_;

	my @res;

	my $Doc_n = @{ $docRef };
	my $i = 0;
	my $flipflop = 0;

	while ($i < $Doc_n) {
		my $pre = $i;
		my $post = $i + 1; # post is past-of-end, i.e., sequence is [$pre, $post)
		my $n = scalar(@{ $docRef->[$i] });
		while ($n < $size) {
			if ($flipflop) {
				# decrement $pre if possible
				if ($pre != 0) {
					$pre--;
					$n+= scalar(@{ $docRef->[$pre] });
				}
			} else {
				if ($post != $Doc_n) {
					$n+= scalar(@{ $docRef->[$post] });
					$post++;
				}
			}
			$flipflop = !$flipflop;
		}
		my @new_ctx = &compose_ctx($docRef, $i, $pre, $post);
		push @res, \@new_ctx;
		$i++;
	}
	return @res;
}

sub compose_ctx {

	my ($D, $cur, $pre, $post) = @_;

	my @res;

	for (my $i = $pre; $i < $post; $i++) {
		if ($i == $cur) {
			push @res, join(" ", map { "$_#1" } @{ $D->[$i] });
		} else {
			push @res, join(" ", map { "$_#0" } @{ $D->[$i] });
		}
	}

	return @res;
}

# In case there is only one sentence (or no sentence makers), create
# contexts by window slicing

sub create_ctxs_nosentence {

	my ($wRef, $size) = @_;

	my @res;

	my $W_n = @{ $wRef };
	my $i = 0;
	my $flipflop = 0;
	my $post_w = $size / 2;
	my $pre_w = $size / 2;
	$pre_w++ if $size % 2;

	while ($i < $W_n) {
		my $pre = $i - $pre_w;
		my $post = $i + $post_w;

		if ($pre < 0) {
			$post -= $pre;
		} elsif ($post > $W_n) {
			$pre -= $post - $W_n;
		}
		$pre=0 if $pre < 0;
		$post = $W_n if $post > $W_n;

		my @ctx;
		@ctx = map { "$_#0" } @{ $wRef }[$pre..$i-1] if $i;
		push @ctx, "$wRef->[$i]#1";
		push @ctx, map { "$_#0" } @{ $wRef }[$i + 1..$post-1] if $i != $W_n - 1;
		push @res, \@ctx;
		$i++;
	}
	return @res;
}

sub wid {
	my $wf_elem = shift;
	my $wid = $wf_elem->getAttribute('id');
	return $wid if defined $wid;
	return $wf_elem->getAttribute('wid');
}

sub tid {
	my $term_elem = shift;
	my $tid = $term_elem->getAttribute('id');
	return $tid if defined $tid;
	return $term_elem->getAttribute('tid');
}

sub getSentences {

	my ($root) = @_;

	my %tid2telem;

	my $wid2sent;	   # { wid => sid }
	my $wid2off;	   # { wid => off } note: offset is position in sentence
	my $WW;			   # { sid => { V => [ w1, w2, w3, ...], ids => [ wid1, wid2 ] }
	my $Sids;		   # [ sid1, sid2, ... ]

	($Sids, $WW, $wid2sent, $wid2off) = &sentences_words($root);

	my $Terms = {}; # { sid => [ { lemma => lema, pos=>pos, valid => 1, span => [ a1, b1 ], spanid => [ w1, w2 ] }, ... ] }
	my $MW = {}; # { sid => [ { lemma => lema, pos=>pos, valid => 1, span = >[ a1, b1 ], spanid => [ w1, w2 ] }, ... ] }
	# note: spans are inervals with [a, b]

	$Terms = &sentences_term_spans($root, $wid2sent, $wid2off);
	$MW = &sentences_match_spans($Sids, $WW);

	my $Ctxs = [];
	foreach my $sid (@{ $Sids }) {
		my $ctx = &harmonize_terms_mw($Terms->{$sid}, $MW->{$sid}); # [ { lema => lema, pos => pos, valid => 1, id => tid, spanid => [wid1, wid2] } ...]
		push @{ $Ctxs }, $ctx if @{ $ctx };
	}

	return ($Sids, $Ctxs);
	# $idRef->[0] -> id of first setence
	# $docRef->[0] firt sentence ([ { lema => lema, pos => pos, id => tid, spanid => [wid1, wid2] } ...])
}

sub harmonize_terms_mw {

	my ($terms, $mws) = @_;

	# [ { lemma => lema, pos=>pos, span => [ a1, b1 ], spanid => [ w1, w2 ] }, ... ]

	my $ctx = [];				# ["lemma#pos#tid", "lemma#pos#tid" ...]
	my $i_term = 0;
	my $m_term = @{ $terms };
	my $i_mw = 0;
	my $m_mw = @{ $mws };
	while (1) {
		# iterate term until it "reaches" i-th mw
		while ($i_term < $m_term and &span_cmp($terms->[$i_term]->{span}, $mws->[$i_mw]->{span} ) == -1) {
			&push_ctx($ctx, $terms->[$i_term]) if $terms->[$i_term]->{valid};
			$i_term++;
		}
		last unless $i_term < $m_term;
		&push_ctx($ctx, $mws->[$i_mw]);
		# iterate term until it "passes" the i-th mw
		$i_term++ while($i_term < $m_term and &span_cmp($terms->[$i_term]->{span}, $mws->[$i_mw]->{span}) != 1);
		# increase mw
		$i_mw++;
		last unless $i_mw < $m_mw;
	}
	for (my $i = $i_term; $i < $m_term; $i++) {
		&push_ctx($ctx, $terms->[$i]) if $terms->[$i]->{valid};
	}
	for (my $i = $i_mw; $i < $m_mw; $i++) {
		&push_ctx($ctx, $mws->[$i]);
	}
	return $ctx;
}

sub push_ctx {

	my ($ctx, $tmw) = @_;
	state $id_n = 0;

	$id_n++;
	my $id = "mark".$id_n;
	return unless $tmw->{pos};
	foreach my $pos (split(//, $tmw->{pos})) {
		push @{ $ctx }, { lemma => $tmw->{lemma}, pos => $pos, id=> $id, spanid => $tmw->{spanid} } ;
	}

}

sub sentences_term_spans {

	my ($root, $wid2sent, $wid2off) = @_;

	my $Terms = {}; # { sid => [ { id => tid, lemma => lema, pos=>pos, span => [ a1, b1 ] }, ... ] }

	foreach my $term_elem ($root->findnodes('terms/term')) {

		my $lemma = &filter_lemma($term_elem->getAttribute('lemma'));
		my $pos = $term_elem->getAttribute('pos');
		$pos = &trans_pos($pos);
		my $tid = &tid($term_elem);

		my %sids;
		my @spanids;
		my ($a, $b);			# span interval
		foreach my $target_elem ($term_elem->getElementsByTagName('target')) {
			my $wid = $target_elem->getAttribute('id');
			my $wsid = $wid2sent->{$wid};
			next unless defined $wsid;
			my $off = $wid2off->{$wid};
			next unless defined $off;
			push @spanids, $wid;
			$sids{$wsid} = 1;
			$a = $off if not defined $a or $off < $a;
			$b = $off if not defined $b or $off > $b;
		}
		next unless defined $a;
		my @sent_ids= keys %sids;
		next unless @sent_ids;
		warn "Error: term $tid crosses sentence boundaries!\n" if @sent_ids > 1;
		my $sid = shift @sent_ids;
		push @{ $Terms->{$sid} }, { lemma => $lemma, valid => $VOCAB->in_dict($lemma), pos => $pos, span => [$a, $b], spanid => \@spanids };
	}
	my $Result = {};
	# sort all according the spans
	while (my ($k, $v) = each %{ $Terms }) {
		my @sv = sort { $a->{span}->[0] <=> $b->{span}->[0] } @{ $v } ;
		$Result->{$k} = \@sv;
	}
	return $Result;
}

sub sentences_match_spans {

	my ($Sids, $WW) = @_;
	my $MW = {}; # { sid => [ { id => mwid, lemma => lema, pos=>pos, span => [ a1, b1 ], spanid => [w1, w2, w3] }, ... ] }

	foreach my $sid ( @{ $Sids } ) {
		my $mw = [];
		my $W = $WW->{$sid};
		my ($spans, $lemmas, $poses) = $VOCAB->match_idx($W->{V}, 1);
		for (my $i = 0; $i < @{ $spans }; $i++) {
			my @ids = @{ $W->{ids} }[ $spans->[$i]->[0] .. $spans->[$i]->[1] ];
			push @{ $mw }, { lemma => $lemmas->[$i], pos => $poses->[$i], span => $spans->[$i], spanid => \@ids };
		}
		$MW->{$sid} = $mw;
	}
	return $MW;
}

sub sentences_words {

	my ($root) = @_;

	my $wid2sent = {} ;	# { wid => sid }
	my $wid2off = {};   # { wid => off } note: offset is position in sentence
	my $WW;			    # { sid => { V => [ w1, w2, w3, ...], ids => [ wid1, wid2 ] }
	my $S = [];		    # [ sid1, sid2, ... ]
	my $W = [];
	my $ID = [];
	my $last_sid = undef;
	my $last_off = 0;
	foreach my $wf_elem ($root->findnodes('text//wf')) {
		my $wid = &wid($wf_elem);
		my $str = $wf_elem->textContent;
		next unless $str;
		my $sent_id = $wf_elem->getAttribute('sent');
		$sent_id ="fake_sent" unless $sent_id;
		substr($sent_id, 0, 0) = "s" if $sent_id =~ /^\d/;
		if (not defined $last_sid or $sent_id ne $last_sid) {
			if (defined $last_sid) {
				$WW->{$last_sid} = { V => $W, ids => $ID } if @{ $W };
				push @{ $S }, $last_sid;
			}
			$last_sid = $sent_id;
			$W = [];
			$ID = [];
			$last_off = 0;
		}
		$wid2sent->{$wid}= $sent_id;
		push @{ $W }, $str;
		push @{ $ID }, $wid;
		$wid2off->{$wid} = $last_off;
		$last_off++;
	}
	if ( @{ $W } ) {
		$WW->{$last_sid} = { V => $W, ids => $ID };
		push @{ $S }, $last_sid;
	}

	return ($S, $WW, $wid2sent, $wid2off);
}

sub span_cmp {

	my ($s1, $s2) = @_;
	return -1 if ($s1->[1] < $s2->[0]);
	return +1 if ($s1->[0] > $s2->[1]);
	return 0;
}


sub filter_lemma {

	my $lemma = shift;

	return undef unless $lemma;
	return undef if $lemma =~ /\#/;	# ukb does not like '#' characters in lemmas
	$lemma =~s/\s/_/go;	     # replace whitespaces with underscore (for mws)
	return $lemma;
}

sub w_count {

	my $aref = shift;
	my $n = 0;
	foreach (@{$aref}) {
		$n+=scalar @{$_};
	}
	return $n;
}

sub trans_pos {

	my ($pos) = @_;

	my @k = keys %POS_MAP;
	return $pos unless @k;		# if no map, just return input.

	foreach my $posre (keys %POS_MAP) {
		return $POS_MAP{$posre} if $pos =~ /$posre/i ;
	}
	return undef;				# no match
}

sub read_pos_map {

	my $fname = shift;

	open(my $fh, $fname) || die "Can't open $fname:$!\n";
	my %H;
	while (<$fh>) {
		chomp;
		my ($k, $v) = split(/\s+/, $_);
		$H{$k}=$v;
	}
	return %H;
}

sub try_wsd {

	my $cmd = shift;
	my $v = qx($cmd --version);
	my $ok = ($? == 0);
	chomp $v;
	return "" unless $ok;
	return $v;
}

sub create_markables_layer {

	my ($xmldoc, $idRef, $docRef) = @_;

	my $naf_elem = $xmldoc->getDocumentElement;
	my $id2mark = {};
	my $markables_elem = $xmldoc->createElement("markables");
	$markables_elem->setAttribute("source", "ukb_wsd_mw");
	my $Sents = [];
	foreach my $doc ( @{ $docRef } ) {
		my $ctx = [];
		foreach my $cw ( @{ $doc } ) {
			my $mark_elem = $xmldoc->createElement("mark");
			my $markid = $cw->{id};
			$mark_elem->setAttribute("id", $markid);
			$mark_elem->setAttribute("lemma", $cw->{lemma});
			$mark_elem->setAttribute("pos", $cw->{pos}) if $cw->{pos};
			my $span_elem = $xmldoc->createElement("span");
			foreach my $wid ( @{ $cw->{spanid} } ) {
				my $tgt_elem = $xmldoc->createElement("target");
				$tgt_elem->setAttribute("id", $wid);
				$span_elem->addChild($tgt_elem);
			}
			$mark_elem->addChild($span_elem);
			$markables_elem->addChild($mark_elem);
			$id2mark->{ $markid } = $mark_elem;
			push @{ $ctx }, join("#", $cw->{lemma}, $cw->{pos}, $markid);
		}
		push @{ $Sents }, $ctx;
	}
	$naf_elem->addChild($markables_elem);
	return ($Sents, $id2mark);
}

sub add_lp_header {

	my ($doc, $beg_tstamp, $end_tstamp) = @_;

	# see if kafHeader exists and create if not

	my ($doc_elem_name, $hdr_elem) = &locate_hdr_elem($doc);
	if (! defined($hdr_elem)) {
		# create and insert as first child of KAF element
		my ($kaf_elem) = $doc->findnodes("/$doc_elem_name");
		die "root <$doc_elem_name> element not found!\n" unless defined $kaf_elem;
		my ($fchild_elem) = $doc->findnodes("/$doc_elem_name/*");
		my $hdr_name = lc($doc_elem_name)."Header";
		$hdr_elem = $doc->createElement($hdr_name);
		$kaf_elem->insertBefore($hdr_elem, $fchild_elem);
	}

	# see if <linguisticProcessor layer="terms"> exists and create if not

	my ($lingp_elem) = $hdr_elem->findnodes('//linguisticProcessors[@layer="terms"]');
	if (! defined($lingp_elem)) {
		$lingp_elem = $doc->createElement('linguisticProcessors');
		$lingp_elem->setAttribute('layer', 'terms');
		$hdr_elem->addChild($lingp_elem);
	}

	my $lp_elem = $doc->createElement('lp');
	$lp_elem->setAttribute('name', 'ukb');
	$lp_elem->setAttribute('version', $UKB_VERSION);
	$lp_elem->setAttribute('beginTimestamp', $beg_tstamp);
	$lp_elem->setAttribute('endTimestamp', $end_tstamp);
	$lp_elem->setAttribute('hostname', hostname);
	$lingp_elem->addChild($lp_elem);
}

# second level element, ending with "*Header"
sub locate_hdr_elem {
	my $doc = shift;
	my $doc_elem = $doc->getDocumentElement;
	foreach my $child_elem ($doc_elem->childNodes) {
		next unless $child_elem->nodeType == XML::LibXML::XML_ELEMENT_NODE;
		return ($doc_elem->nodeName, $child_elem) if $child_elem->nodeName =~ /Header$/;
	}
	return ($doc_elem->nodeName, undef);
}

sub get_datetime {

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=gmtime(time);
	return sprintf "%4d-%02d-%02dT%02d:%02d:%02dZ", $year+1900,$mon+1,$mday,$hour,$min,$sec;

}

sub usage {

	my $str = shift;

	print STDERR $str."\n";
	die "usage: $0 [-x wsd_executable] [-m pos_mapping_file ] -K kbfile.bin -D dict.txt naf_input.txt [-- wsd_executable_options]\n";

}
