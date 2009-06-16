#!/usr/bin/perl

use strict;

use XML::LibXML;
use File::Temp;
use IPC::Open3;
use IO::Select;
use Symbol; # for gensym

use Getopt::Std;

my %opts;

getopts('x:m:M:W:', \%opts);

my $wsd_exec = $opts{'x'} ? $opts{'x'} : "./ukb_wsd";
my $kb_binfile = $opts{'M'};
my $dict_file = $opts{'W'};

my $fname = shift;

&usage("Error: no dictionary") unless -f $dict_file;
&usage("Error: no KB graph") unless -f $kb_binfile;
&usage("Error: can't execute $wsd_exec") unless &try_wsd($wsd_exec);

my $wsd_extraopts;

if (@ARGV && $ARGV[0] eq "--") {
  shift @ARGV;
  $wsd_extraopts = join(" ", @ARGV);
}

my $wsd_cmd = " $wsd_exec -K $kb_binfile -D $dict_file --allranks $wsd_extraopts";

# default POS mapping for KAF

my %pos_map = ("N.*" => 'n',
	       "R.*" => 'n',
	       "G.*" => 'a',
	       "V.*" => 'v',
	       "A.*" => 'r');

%pos_map = &read_pos_map( $opts{'m'} ) if $opts{'m'};

my $parser = XML::LibXML->new();
my $doc = $parser->parse_file($fname);
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
  die "Error: no term $tid.\n" unless $term_elem;
  my $senseAlt_elem = $doc->createElement('senseAlt');

  foreach my $sid (sort {$h->{$b} <=> $h->{$a}} keys %{ $h }) {
    my $sense_elem = $doc->createElement('sense');
    $sense_elem->setAttribute('sensecode', $sid);
    $sense_elem->setAttribute('confidence', $h->{$sid} );
    $senseAlt_elem->addChild($sense_elem);
  }
  $term_elem->addChild($senseAlt_elem);
}

print $doc->toString(1)."\n";

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

  $? and die "Error when executing wsd command:\n$wsd_cmd\n";

  open(my $fh, $otmp->filename) || die "Can't open $otmp->filename:$!\n";

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

  my %S;

  foreach my $term_elem ($root->findnodes('terms//term')) {
    my $lemma = $term_elem->getAttribute('lemma');
    next unless $lemma;
    $lemma =~s/\s/_/go;	     # replace whitespaces with underscore (for mws)
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
    my ($sid) = shift @sent_ids;
    push( @{ $S{$sid} }, "$lemma#$pos#$tid");
  }

  my @IDS;
  my @D;

  foreach my $sid (sort { substr($a, 1) <=> substr($b, 1) } keys %S) {
    push @IDS, $sid;
    push @D, $S{$sid};
  }

  return (\@IDS, \@D);
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
  return ""; # no match, return empty string
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
  `$cmd -h`;
  return $? == 0;
}

sub usage {

  my $str = shift;


  print $str."\n";
  die "usage: $0 [-x wsd_executable] [-m pos_mapping_file ] -M kbfile.bin -W dict.txt kaf_input.txt [-- wsd_executable_options]\n";

}
