#!/usr/bin/perl

use strict;

use XML::LibXML;
use File::Temp;
use File::Basename;
use IPC::Open3;
use IO::Select;
use Symbol; # for gensym

binmode STDOUT;

use Getopt::Std;

my %opts;

getopts('x:m:M:W:', \%opts);

my $wsd_exec = $opts{'x'} ? $opts{'x'} : "./ukb_wsd";
my $kb_binfile = $opts{'M'};
my $dict_file = $opts{'W'};

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

my $wsd_extraopts;

if (@ARGV && $ARGV[0] eq "--") {
  shift @ARGV;
  $wsd_extraopts = join(" ", @ARGV);
}

my $wsd_cmd = " $wsd_exec -K $kb_binfile -D $dict_file --allranks $wsd_extraopts";

# default POS mapping for KAF

my %pos_map = ("^N.*" => 'n',
	       "^R.*" => 'n',
	       "^G.*" => 'a',
	       "^V.*" => 'v',
	       "^A.*" => 'r');

%pos_map = &read_pos_map( $opts{'m'} ) if $opts{'m'};

open(my $fh_fname, $fname);
binmode $fh_fname;

my $parser = XML::LibXML->new();
my $doc = $parser->parse_fh($fh_fname);

my $root = $doc->getDocumentElement;

my ($idRef, $docRef) = &getSentences($root, \%pos_map);

my @Ctxs;
my $ctx_size = &w_count($docRef);

die "Error: no sentences (have you mapped the POS values?)\n" unless $ctx_size;

$ctx_size = 20 if $ctx_size > 20; # contexts of max. 20 words

if (scalar(@{ $docRef }) > 1 ) {
  @Ctxs= &create_ctxs($docRef, $ctx_size);
} else {
  @Ctxs = &create_ctxs_nosentence($docRef->[0], $ctx_size);
  my @ids = map { $idRef->[0] } @Ctxs;
  $idRef = \@ids;
}

my %Sense_map = &wsd($wsd_cmd, \@Ctxs, $idRef);	# { tid => { sense => score } }

while (my ($tid, $h) = each %Sense_map) {
  next unless scalar keys %{ $h };
  my ($term_elem) = $doc->findnodes("//term[\@tid='$tid']");
  if (!defined($term_elem)) {
    # See if compound
    ($term_elem) = $doc->findnodes("//term/component[\@id='$tid']");
  }
  die "Error: no term/component with id $tid.\n" unless $term_elem;
  my $xrefs_elem = $doc->createElement('externalReferences');
  foreach my $sid (sort {$h->{$b} <=> $h->{$a}} keys %{ $h }) {
    my $xref_elem = $doc->createElement('externalRef');
    $xref_elem->setAttribute('resource', $kb_resource);
    $xref_elem->setAttribute('reference', $sid);
    $xref_elem->setAttribute('confidence', $h->{$sid} );
    $xrefs_elem->addChild($xref_elem);
  }
  $term_elem->addChild($xrefs_elem);
}

&add_lp_header($doc);

$doc->toFH(\*STDOUT, 1)."\n";

sub wsd {

  my ($cmd, $ctxRef, $idRef) = @_;

  my $ftmp = File::Temp->new();
  die "Can't create temporal file:$!\n" unless $ftmp;
  binmode ($ftmp, ':utf8');

  for(my $i=0; $i < scalar @{ $ctxRef }; $i++) {
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
  <$fh>; # skip first line
  while(my $inst = <$fh>) {
    chomp ($inst);
    my ($sent, $tid, @sid) = split(/\s+/, $inst);
    pop @sid; # lemma
    pop @sid; # comment mark
    foreach my $item (@sid) {
      my ($sid, $w) = split(/\//, $item);
      $w = 1 unless $w;
      $H{$tid}->{$sid} = $w;
    }
  }
  return %H;
}

sub run_wsd {

  my $cmd = shift;
  my @result;
  my ($infh,$outfh,$errfh); # these are the FHs for our child
  $errfh = gensym(); # we create a symbol for the errfh
                     # because open3 will not do that for us

  my $pid;

  eval{
    $pid = open3($infh, $outfh, $errfh, $cmd);
  };
  die "$@\n" if $@;

  my $sel = new IO::Select; # create a select object to notify
                            # us on reads on our FHs
  $sel->add($outfh,$errfh); # add the FHs we're interested in

  while(my @ready = $sel->can_read) { # read ready
    foreach my $fh (@ready) {
      my $line = <$fh>; # read one line from this fh
      if(not defined $line){ # EOF on this FH
	$sel->remove($fh); # remove it from the list
	next;              # and go handle the next FH
      }
      if($fh == $outfh) {     # if we read from the outfh
	chomp $line;
	push @result, $line;
#       } elsif($fh == $errfh) {# do the same for errfh
# 	print "stderr:". $line;
#       } else { # we read from something else?!?!
# 	die "Shouldn't be here\n";
      }
    }
  }
  shift @result; # first line is comment
  return @result;
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

sub getSentences {

  my ($root, $pos_map) = @_;

  my %w2sent;
  foreach my $wf_elem ($root->findnodes('text//wf')) {
    my $sent_id = $wf_elem->getAttribute('sent');
    $sent_id ="fake_sent" unless $sent_id;
    $w2sent{$wf_elem->getAttribute('wid')}= $sent_id;
  }

  my %S; # { sentence_id => [ "lemma#pos#tid", ... ] }

  foreach my $term_elem ($root->findnodes('terms//term')) {

    my $lemma = &filter_lemma($term_elem->getAttribute('lemma'));
    next unless $lemma;
    my $pos = $term_elem->getAttribute('pos');
    $pos = &tr_pos($pos_map, $pos);
    next unless $pos;
    my $tid = $term_elem->getAttribute('tid');

    my %sids;
    foreach my $target_elem ($term_elem->getElementsByTagName('target')) {
      my $wsid = $w2sent{$target_elem->getAttribute('id')};
      next unless defined $wsid;
      $sids{$wsid} = 1;
    }

    my @sent_ids= keys %sids;
    next unless @sent_ids;
    warn "Error: term $tid crosses sentence boundaries!\n" if @sent_ids > 1;
    my $sid = shift @sent_ids;
    push( @{ $S{$sid} }, "$lemma#$pos#$tid");

    # treat components

    foreach my $comp_elem ($term_elem->getElementsByTagName('component')) {
      my $comp_id = $comp_elem->getAttribute('id');
      my $comp_pos = $comp_elem->getAttribute('pos');
      my $comp_lemma = &filter_lemma($comp_elem->getAttribute('lemma'));
      next unless defined $comp_id;
      next unless defined $comp_lemma;
      if ($comp_pos) {
	my $comp_pos_tr = &tr_pos($pos_map, $comp_pos);
	next unless $comp_pos_tr;
	push( @{ $S{$sid} }, "$comp_lemma#$comp_pos_tr#$comp_id");
      } else {
	# no pos found in component. Try with all pos
	my %saw;
	foreach my $aux_pos (grep(!$saw{$_}++, values %{$pos_map}) ) {
	  push( @{ $S{$sid} }, "$comp_lemma#$aux_pos#$comp_id");
	}
      }
    }
  }

  my @IDS;
  my @D;

  foreach my $sid (sort { substr($a, 1) <=> substr($b, 1) } keys %S) {
    push @IDS, $sid;
    push @D, $S{$sid};
  }

  return (\@IDS, \@D);
}


sub filter_lemma {

  my $lemma = shift;

  return undef unless $lemma;
  return undef if $lemma =~ /\#/;  # ukb does not like '#' characters in lemmas
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

sub tr_pos {

  my ($pos_map, $pos) = @_;

  my @k = keys %{ $pos_map };
  return $pos unless @k; # if no map, just return input.

  foreach my $posre (keys %{ $pos_map }) {
    return $pos_map->{$posre} if $pos =~ /$posre/i;
  }
  return undef; # no match
}

sub read_pos_map {

  my $fname = shift;

  open(my $fh, $fname) || die "Can't open $fname:$!\n";
  my %H;
  while(<$fh>) {
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

sub add_lp_header {

  my $doc = shift;

  # see if kafHeader exists and create if not

  my ($hdr_elem) = $doc->findnodes("/KAF/kafHeader");
  if (! defined($hdr_elem)) {
    # create and insert as first child of KAF element
    my ($kaf_elem) = $doc->findnodes("/KAF");
    die "root <KAF> element not found!\n" unless defined $kaf_elem;
    my ($fchild_elem) = $doc->findnodes("/KAF/*");
    $hdr_elem = $doc->createElement('kafHeader');
    $kaf_elem->insertBefore($hdr_elem, $fchild_elem);
  }

  # see if <linguisticProcessor layer="terms"> exists and create if not

  my ($lingp_elem) = $hdr_elem->findnodes("//linguisticProcessors[layer='text']");
  if(! defined($lingp_elem)) {
    $lingp_elem = $doc->createElement('linguisticProcessors');
    $lingp_elem->setAttribute('layer', 'terms');
    $hdr_elem->addChild($lingp_elem);
  }

  my $lp_elem = $doc->createElement('lp');
  $lp_elem->setAttribute('name', 'ukb');
  $lp_elem->setAttribute('version', $UKB_VERSION);
  $lp_elem->setAttribute('timestamp', &get_datetime());
  $lingp_elem->addChild($lp_elem);
}


sub get_datetime {

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime(time);
return sprintf "%4d-%02d-%02dT%02d:%02d:%02dZ", $year+1900,$mon+1,$mday,$hour,$min,$sec;

}

sub usage {

  my $str = shift;


  print $str."\n";
  die "usage: $0 [-x wsd_executable] [-m pos_mapping_file ] -M kbfile.bin -W dict.txt kaf_input.txt [-- wsd_executable_options]\n";

}
