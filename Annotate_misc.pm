package Annotate_misc;

use strict;
use warnings;
use English;
use Carp;
use Data::Dumper;

#use version;
our $VERSION = qw('1.2.1'); # May 10 2013
use File::Temp qw/ tempfile tempdir /;
use Bio::SeqIO;
use Bio::Seq;
use IO::String;

use Annotate_Align;      # Ran MSA, and get ready for actually cut the mat_peptides
use Annotate_Def;        # Have the approved RefSeqs, also load taxon info and definition of gene symbols
use Annotate_Download;   # Download the RefSeqs and taxon info from NCBI, and check against data stored in file
use Annotate_gbk;	 # for annotation from genbank
use Annotate_Math;       # Get the mat_peptide location, based on alignment with reference
use Annotate_Util;       # assemble the feature for newly annotated mat_peptide, plus other things like checking
use Annotate_Verify;     # Check the quality of the set of annotation

my $debug_all = 0;

####//README//####
#
# Annotate_misc contains the misc subroutine
#
#    Authors Guangyu Sun, gsun@vecna.com; Chris Larsen, clarsen@vecna.com
#    February 2010
#
##################

## //EXECUTE// ##

## turns on/off the debug in each module

sub setDebugAll {
    my ($debug) = @_;
    $debug_all = $debug;
    1 && Annotate_Align::setDebugAll( $debug);
    0 && Annotate_gbk::setDebugAll( $debug);
    1 && Annotate_Def::setDebugAll( $debug);
    0 && Annotate_Download::setDebugAll( $debug);
    1 && Annotate_Math::setDebugAll( $debug);
    1 && Annotate_Util::setDebugAll( $debug);
    0 && Annotate_Verify::setDebugAll( $debug);
} # sub setDebugAll


=head2 generate_fasta
Takes an array of SeqFeature.
 Write the translations to a virtual file
 Returns the fasta file in a string
=cut

sub generate_fasta {
    my ($feats_all) = @_;

    my $debug = 0 && $debug_all;
    my $subname = 'generate_fasta';

    my $seq_out;
    my $faa1 = '';
    my $vfile = IO::String->new($faa1);
    $seq_out = Bio::SeqIO->new(
                  '-fh'     => $vfile,
                  '-format' => 'fasta'
                              );
    # Following sort causes wrong ordering in AF126284
#    foreach my $feat (sort {$a->location->start <=> $b->location->start} @$feats_all) {
    foreach my $feat (@$feats_all) {

        $debug && print STDERR "$subname: \$feat=\n". Dumper($feat) . "End of \$feat\n";
        next if ($feat->primary_tag eq 'CDS'); # Exclude CDS
        my @values = $feat->get_tag_values('translation');
        my $s = $values[0];
        my $desc;
        if ($feat->has_tag('note')) {
            @values = $feat->get_tag_values('note');
            foreach my $value (@values) {
                $desc = $1 if ($value =~ /^Desc:(.+)$/i);
            }
        } elsif($feat->has_tag('product')) {
            $desc = 'ACC='.$feat->seq->accession_number;
            $desc .= '.'.$feat->seq->version; # Add version of accession to description
            @values = $feat->get_tag_values('product');
            $desc .= '|product='.$values[0];
            $desc .= '|Loc='.$feat->location->to_FTstring;
        }
        my $f = Bio::PrimarySeq->new(
                         -seq      => $s,
                         -id       => '',	# id can't contain space
                         -desc     => $desc,	# desc can contain space
                         -alphabet => 'protein'
                                    );
        if ($f->alphabet eq 'dna') {
            $seq_out->write_seq($f->translate());
        } elsif($f->alphabet eq 'protein') {
            $seq_out->write_seq($f);
        }

    }

    return $faa1;
} # sub generate_fasta


sub readGenbank {
    my ($acc, $number, $dbh_ref) = @_;

    my $debug = 0 || $debug_all;
    my $subname = 'readGenbank';

        # get genbank file
        my $result;
        print STDERR "\n";
        $debug && print STDERR "$subname: \$acc='$acc'\n";
        if ($dbh_ref && $dbh_ref->isa('GBKUpdate::Database')) {
            # get genome gbk from MySQL database
            $result = $dbh_ref->get_genbank($acc);
            $result = $result->[0];
            print STDERR "$subname: \$acc='#$number:$acc' Found record in MySQL database\n";

            # Turn on following 'if' section to save genbank file to file
            if ( 0 && $result ) {
                open my $out, '>', "${acc}.gb" or croak "$0: Couldn't open ${acc}.gb: $OS_ERROR";
                print $out "$result";
                close $out or croak "$0: Couldn't close ${acc}.gb: $OS_ERROR";
                print STDERR "$subname: \$acc='#$number:$acc' written to file ${acc}.gb\n";
                next;
            }

        } elsif (-r "$acc") {
            # This $acc is really a filename
            open my $in, '<', "$acc" or croak "$0: Couldn't open $acc: $OS_ERROR";
            $result = do { local $/; <$in>};
            close $in or croak "$0: Couldn't close $acc: $OS_ERROR";
            print STDERR "$subname: \$acc='#$number:$acc' Found record in file=$acc\n";
        }

    return $result;

} # sub readGenbank


sub process_list1 {
    my ($accs, $aln_fn, $dbh_ref, $exe_dir, $exe_name, $dir_path, $inFormat, $inTaxon, $outFormat) = @_;

    my $debug = 0 || $debug_all;
    my $subname = 'process_list1';

    my $progs = Annotate_Def::getProgs();

#    my $refseqs = {};

   my $msgs = [];
   my $count = {
         MSA=>{Success=>0, Fail=>0, Empty=>0},
         GBK=>{Success=>0, Fail=>0, Empty=>0},
   };
   for (my $ct = 0; $ct<=$#{$accs}; $ct++) {
        my $msg_msa = '';
        my $msg_gbk = '';
        my $faa = '';
        my $number = $accs->[$ct]->[0];
        my $acc = $accs->[$ct]->[1];

        print STDERR "\n";
        # get genbank file
        my $result = &readGenbank($acc, $number, $dbh_ref);

        print STDERR "$subname: #$number:\t$acc processing\n";

        my $gbk = $result;
        my $in_file2 = IO::String->new($gbk);
        my $in;
        if ($inFormat =~ m/genbank/i) {
            $in  = Bio::SeqIO->new( -fh => $in_file2, -format => 'genbank' );
        } elsif ($inFormat =~ m/fasta/i) {
            $in  = Bio::SeqIO->new( -fh => $in_file2, -format => 'fasta' );
        }
#        $debug && print STDERR "$subname: \$in='\n". Dumper($in) . "End of \$in\n\n";
while (
        my $inseq = $in->next_seq()#;
) {
        $debug && print STDERR "$subname: \$inseq='\n". Dumper($inseq) . "End of \$inseq\n\n";
        if (!$result || !$inseq) {
            print STDERR "$subname: \$acc=$acc \$inseq is undef, skip\n";
            my $msg = "$acc \ttaxid=---- \tsrc=MSA \tstatus=---- \tcomment=Empty genome file";
            print STDERR "$subname: \$msg=$msg\n";
            push @$msgs, $msg;
            $msg = "$acc \ttaxid=---- \tsrc=GBK \tstatus=---- \tcomment=Empty genome file";
            print STDERR "$subname: \$msg=$msg\n";
            push @$msgs, $msg;
            $count->{MSA}->{Empty}++;
            $count->{GBK}->{Empty}++;
            next;
        } elsif ($result) {
            print STDERR "$subname: \$result='".substr($result,0,(length($result)>79)?79:length($result))."'\n";
            $debug && print STDERR "$subname: \$result='$result'\n";
        }
        my $taxid;
        if ($inFormat =~ m/genbank/i) {
            $acc = $inseq->accession_number;
            $taxid = $inseq->species->ncbi_taxid;
        } elsif ($inFormat =~ m/fasta/i) {
            $taxid = $inTaxon;
        }
        $debug && print STDERR "$subname: accession='$acc' \$taxid=$taxid.\n";
        my $outfile = '';
        $outfile = "$dir_path/$acc" . '_matpept_msagbk.faa' if (!$debug);
        $debug && print STDERR "$subname: accession='#$number:$acc' \$outfile=$outfile.\n";
        
        # Now run the annotation by MUSCLE or CLUSTALW alignment
        my ($feats_msa, $comment_msa);
        if ($inFormat =~ m/genbank/i) {
#            ($feats_msa, $comment_msa) = Annotate_Align::annotate_1gbk( $gbk, $exe_dir, $aln_fn, $dir_path, $progs);
            ($feats_msa, $comment_msa) = Annotate_Align::annotate_1gbk( $inseq, $exe_dir, $aln_fn, $dir_path, $progs);
        } elsif ($inFormat =~ m/fasta/i) {
            ($feats_msa, $comment_msa) = Annotate_Align::annotate_1faa( $gbk, $inTaxon, $exe_dir, $aln_fn, $dir_path, $progs);
        }
#        $feats_msa = undef; # Used to test the subroutines in Annotate_gbk
        my $status_msa = ($feats_msa)                                                           ? 'Success'
                       : ($comment_msa eq 'Refseq with mat_peptide annotation from NCBI, skip') ? 'Skip   '
                       :                                                                          'Fail   ';
        if (!$feats_msa) {
            $count->{MSA}->{Fail}++;
            print STDERR "$subname: no result from Annotate_Align::annotate_1gbk comment=$comment_msa\n";
        } else {
            $count->{MSA}->{Success}++;
            $debug && print STDERR "$subname: \$feats_msa='\n". Dumper($feats_msa) . "End of \$feats_msa\n\n";
            for my $k (sort keys %$feats_msa) {
              for my $f (@{$feats_msa->{$k}}) {
                my $p = ($f->has_tag('note')) ? ($f->get_tag_values('note'))[1] : '';
                $debug && print STDERR "$subname: $p\n";
              }
            }
        }
        $msg_msa = "$acc \ttaxid=$taxid \tsrc=MSA \tstatus=$status_msa \tcomment=$comment_msa";
        push @$msgs, $msg_msa;
        print STDERR "$subname: \$msg=$msg_msa\n";

        my $faa1 = '';
        # Order the resulting mat_peptides according to the start positions in the CDS
        my $refcds_ids = [ keys %$feats_msa ];
        $debug && print STDERR "$subname: \$refcds_ids='@$refcds_ids'\n";
        for my $i (0 .. $#{$refcds_ids}) {
            my $feats = $feats_msa->{$refcds_ids->[$i]};
            if (!$feats->[0]) {
                print STDERR "$subname: ERROR: NULL feature found for \$id=$refcds_ids->[$i]\n";
                next;
            }
            my $start1 = $feats->[0]->location->start;
            for my $j ($i+1 .. $#{$refcds_ids}) {
              $debug && print STDERR "$subname: \$i=$i \$feats_msa='\n". Dumper($feats_msa) . "End of \$feats_msa\n\n";
              my $feats = $feats_msa->{$refcds_ids->[$j]};
              next if ($#{$feats}<0);
              $debug && print STDERR "$subname: \$i=$i \$j=$j \$feats='\n". Dumper($feats) . "End of \$feats\n\n";
              $debug && print STDERR "$subname: \$i=$i \$j=$j \$refcds_ids='\n". Dumper($refcds_ids) . "End of \$refcds_ids\n\n";
              my $start2 = $feats->[0]->location->start;
              $debug && print STDERR "$subname: \$start1=$start1 \$start2=$start2\n";
              if ($start1 > $start2) {
                my $temp = $refcds_ids->[$i];
                $refcds_ids->[$i] = $refcds_ids->[$j];
                $temp = $refcds_ids->[$j] = $temp;
              }
            }
        }
        $debug && print STDERR "$subname: \$refcds_ids='@$refcds_ids'\n";

        $faa1 = Annotate_misc::get_msa_fasta( $refcds_ids, $feats_msa, $acc);
        $debug && print STDERR "$subname: accession=$acc \$faa1 = '\n$faa1'\n";

        # Gets a FASTA string containing all mat_peptides from genbank file
#        my ($feats_gbk, $comment_gbk) = Annotate_gbk::get_matpeptide( $gbk, $feats_msa,$exe_dir);
        my ($feats_gbk, $comment_gbk) = Annotate_gbk::get_matpeptide( $inseq, $feats_msa,$exe_dir);
        my $status_gbk = ($feats_gbk)                         ? 'Success'
                       : ($comment_gbk eq 'Not refseq, skip') ? 'Skip   '
                       :                                        'Fail   ';
        if (!$feats_gbk) {
            $count->{GBK}->{Fail}++;
            print STDERR "$subname: \$acc=$acc Empty result from Annotate_gbk::get_matpeptide comment=$comment_gbk\n";
        } else {
            $count->{GBK}->{Success}++;
            $debug && print STDERR "$subname: \$feats_gbk='\n$feats_gbk'\nEnd of \$feats_gbk\n\n";
        }
        $msg_gbk = "$acc \ttaxid=$taxid \tsrc=GBK \tstatus=$status_gbk \tcomment=$comment_gbk";
        if ($feats_gbk && $faa1 && $acc !~ /^NC_/i) {
            $msg_gbk .= ". Not refseq, take MSA instead";
        }
        print STDERR "$subname: \$msg_gbk=$msg_gbk\n";
        push @$msgs, $msg_gbk;
        $debug && print STDERR "$subname: \$msgs=\n". Dumper($msgs) . "End of \$msgs\n\n";

        # $faa1 vs. $feats_gbk,
        # Take gbk if the genome is refseq,
        # Take $faa1 if exists
        # otherwise take gbk.
        if ( 0 ) {
            $faa = Annotate_gbk::combine_msa_gbk( $acc, $faa1, $feats_gbk);
        } elsif ($faa1 || $feats_gbk ne '') {
            $faa = $faa1;
            $outfile = "$dir_path/$acc" . '_matpept_msa.faa';
            my $c = [ split(/> /, $faa) ];
            $debug && print STDERR "$subname: \$c=\n". Dumper($c) . "End of \$c\n\n";
            $c = $#{$c};
            my $c_old = [ split(/> /, $feats_gbk) ];
            $debug && print STDERR "$subname: \$c_old=\n". Dumper($c_old) . "End of \$c_old\n\n";
            $c_old = $#{$c_old};
            $debug && print STDERR "$subname: \$c=$c \$c_old=$c_old\n";
#            if (!$faa || $feats_gbk && ($acc =~ /^NC_\d+$/i)) {
            if (!$faa || ($acc =~ /^NC_\d+$/i) && ($c_old>=$c)) {
                $debug && print STDERR "$subname: \$faa=\n". Dumper($faa) . "End of \$faa\n\n";
                $debug && print STDERR "$subname: \$feats_gbk=\n". Dumper($feats_gbk) . "End of \$feats_gbk\n\n";
                $faa = $feats_gbk;
                $outfile = "$dir_path/$acc" . '_matpept_gbk.faa';
            } elsif (($acc =~ /^NC_\d+$/i) && ($c_old<$c)) {
                $faa = Annotate_misc::get_msa_fasta( $refcds_ids, $feats_msa, $acc);
            }

            
            print STDERR "$subname: accession='#$number:$acc' \$outfile=$outfile.\n";
            print STDERR "$subname: \$acc=$acc \$faa=\n${faa}End of \$faa\n\n";

            if ( 1 && $faa && $outfile) {
                open my $OUTFH, '>', $outfile
                    or croak "Can't open '$outfile': $OS_ERROR";
                print {$OUTFH} $faa
                    or croak "Can't write to '$outfile': $OS_ERROR";
                close $OUTFH
                    or croak "Can't close '$outfile': $OS_ERROR";
            }
        }
}

#   exit;

   } # for (my $ct = 0; $ct<=$#{$accs}; $ct++)
#   $debug && print STDERR "$subname: \$refseqs=\n".Dumper($refseqs)."End of \$refseqs\n\n";
#   $debug && print STDERR "$subname: \$inseqs=\n".Dumper($inseqs)."End of \$inseqs\n\n";

    print STDOUT "accession \ttaxonomy \tsource \tstatus \tcomment\n";
    for my $msg (@$msgs) {
        print STDOUT "$msg\n";
    }
    my $summary = '';
    $summary = "\nStatistics of this run:\n";
    $summary .= "Total input genomes: ". ($#{$accs}+1) ."\n";
    for my $key ('MSA','GBK') {
        $summary .= "$key: \t";
        for my $key2 ('Success','Fail','Empty') {
            $summary .= "$key2 \t$count->{$key}->{$key2}\t";
        }
        $summary .= "\n";
    }
    print STDOUT "$summary\n";
    print STDERR "$summary\n";

    print STDERR "$subname: \$msgs=\n". Dumper($msgs) . "End of \$msgs\n\n";
exit;

} # sub process_list1


sub get_msa_fasta {
    my ($refcds_ids, $feats_msa, $acc) = @_;

    my $debug = 0 && $debug_all;
    my $subname = 'get_msa_fasta';

    my $faa1 = '';
    for my $id (@$refcds_ids) {
            my $feats = $feats_msa->{$id};
            if (!$feats->[0]) {
                print STDERR "$subname: ERROR: NULL feature found for \$id=$id\n";
                next;
            }
            $debug && print STDERR "$subname: \$feats=\n". Dumper($feats) . "End of \$feats\n\n";

            # either print to STDERR or fasta file
            $faa1 .= Annotate_misc::generate_fasta( $feats);
            print STDERR "$subname: refcds=$id input $acc ".$feats->[0]->primary_tag."=".$feats->[0]->location->to_FTstring."\n";
#            $debug && print STDERR "$subname: \$faa1 = '\n$faa1'\n";

            Annotate_Verify::check_old_annotation( $acc, $faa1);
#            print STDERR "$subname: accession = '".$acc."'\n";
    }
    $debug && print STDERR "$subname: accession=$acc \$faa1 = '\n$faa1'\n";

    return $faa1;
} # sub get_msa_fasta

sub process_list3 {
    my ($accs, $aln_fn, $dbh_ref, $exe_dir, $exe_name, $dir_path, $test1, $refseq_required) = @_;

    my $debug = 0 && $debug_all;
    my $subname = 'process_list3';

#    $debug && print STDERR "$subname: \$accs=\n".Dumper($accs)."End of \$accs\n\n";
    my $refseqs = {};
    my $inseqs  = [];

   # get all CDS for seqs and refseqs, including the mat_peptides
   for (my $ct = 0; $ct<=$#{$accs}; $ct++) {
        my $refpolyprots = [];
        my $polyprots    = [];
        my $number = $accs->[$ct]->[0];
        my $acc = $accs->[$ct]->[1];

        # get genbank file from MySQL database
        my $result;
        if ($dbh_ref && $dbh_ref->isa('GBKUpdate::Database')) {
            $result = $dbh_ref->get_genbank($acc);
            $result = $result->[0];
        } elsif (-r "$acc") { # This is really a filename
            open my $in, '<', "$acc" or croak "$0: Couldn't open $acc: $OS_ERROR";
            $result = do { local $/; <$in>};
            close $in or croak "$0: Couldn't close $acc: $OS_ERROR";
            print STDERR "$subname: \$result='".substr($result,0,79)."'\n";
        } else {
            print STDERR "$subname: Couldn't find genome \$acc='$acc'\n";
            next;
        }
#        print STDERR "\n$subname: result from database is '@$result'\n";

        if (!$result) {
            print STDERR "$subname: \$ct = $ct \$acc='$acc' result is empty\n";
            next;
        }

        # Now run the annotation
        my $gbk = $result;
#        print STDERR "$subname: \$result=$result->[0]\n";
        my $in_file2 = IO::String->new($gbk);
        my $in  = Bio::SeqIO->new( -fh => $in_file2, -format => 'genbank' );
        # Only take 1st sequence from each gbk (Note: gbk can hold multiple sequences, we ignore all after 1st)
        my $inseq = $in->next_seq();
        my $taxid = $inseq->species->ncbi_taxid;
        print STDERR "\n$subname: \$ct = $ct \$acc='$acc' \$taxid=$taxid processing\n";
#        print STDOUT "$subname: \$ct = $ct \$acc='$acc' \$taxid=$taxid processing\n";

        # determine the refseq, and get the CDS/mat_peptides in refseq
        $refpolyprots = Annotate_Util::get_refpolyprots( $refseqs, $inseq, $exe_dir);
#        $debug && print STDERR "$subname: \$refpolyprots = $#{$refpolyprots}\n";
#        $debug && print STDERR "$subname: \$refpolyprots=\n".Dumper($refpolyprots)."End of \$refpolyprots\n\n";

        if ($#{$refpolyprots} <0) {
            print STDERR "$subname: There is a problem getting refseq for ".$acc.". Skipping\n";
            print STDERR "$subname: \$#{\@\$refpolyprots} ".$#{$refpolyprots}.".\n";
            next;
        }

        # According to refseq, get the CDS/mat_peptides in inseq, use bl2seq to determine if the CDS matches
        my $num_cds;
        ($polyprots, $num_cds) = Annotate_Util::get_polyprots( $inseq, $refpolyprots);
#        $debug && print STDERR "$subname:    \$polyprots = $num_cds\n";
        $debug && print STDERR "$subname: \$polyprots=\n".Dumper($polyprots)."End of \$polyprots\n\n";

        # add refseq to hash, add inseq to array
        if ($#{$refpolyprots} >=0 && $refpolyprots->[0]->[1]->primary_tag eq 'CDS') {
            if (!exists($refseqs->{$refpolyprots->[0]->[1]->seq->accession_number})) {
                $refseqs->{$refpolyprots->[0]->[1]->seq->accession_number} = $refpolyprots;
            }
        } else {
            print STDERR "$subname: There is a problem with ".$acc.". Skipping\n";
            print STDERR "$subname: \$#{\@\$refpolyprots} ".$#{$refpolyprots}.". Skipping\n";
            next;
        }

        my $n = [keys %$polyprots];
        $debug && print STDERR "$subname: polyprotein CDS for acc=".$acc." \$n=$#{$n}\n";
        if ($#{$n} <0) {
            print STDERR "$subname: Can't find any polyprotein CDS for acc=".$acc." \$n=$#{$n}. Skipping\n";
#            print STDOUT "$subname: Can't find any polyprotein CDS for acc=".$acc." \$n=$#{$n}. Skipping\n";
            next;
        }
        push @$inseqs, [$acc, $polyprots];

        if ($test1) {
            $debug && print STDERR "$subname: Processed one file, exit for debug\n";
            last;
        }
   }
   $debug && print STDERR "$subname: \$refseqs=\n".Dumper($refseqs)."End of \$refseqs\n\n";
   $debug && print STDERR "$subname: \$refseqs=".length($refseqs)."\n";
   $debug && print STDERR "$subname: \$inseqs =\n".Dumper($inseqs)."End of \$inseqs\n\n";
   $debug && print STDERR "$subname: \$inseqs =".$#{$inseqs}."\n";

   $debug && print STDERR "$subname: Finished loading all seqs and refseqs, ready to run MUSCLE\n\n";

   $debug && print STDERR "$subname: Number of input genome is $#{$inseqs}.\n";
   if ($#{$inseqs}<0) {
       $debug && print STDERR "$subname: Nothing to process. Return.\n";
       return;
   }

   my $feats_all;
   $feats_all = Annotate_Align::muscle_profile( $refseqs, $inseqs, $aln_fn,$exe_dir);
#   $debug && print STDERR "$subname: \$feats_all=\n". Dumper($feats_all->[0]) . "End of \$feats_all\n\n";

   for (my $i=0; $i<=$#{$feats_all}; $i++) {
       my $feats = $feats_all->[$i];
       for (my $j=0; $j<=$#{$feats}; $j++) {
            my $feats_new = $feats->[$j];
            $debug && print STDERR "$subname: \$j=$j \$feats_new=\n".Dumper($feats_new)."End of \$feats_new\n\n";
            next if (!$feats_new);

            my $outfile = '';
            my $accession_number = $feats_new->[0]->seq->accession_number;
            $outfile = $accession_number . '_matpept_muscle.faa' if (!$debug);
            my $faa1 = Annotate_misc::generate_fasta( $feats_new, $outfile, '');
            $debug && print STDERR "$subname: \$outfile=$outfile\n";
            print STDERR "$subname: \$j=$j/$#{$feats} accession = '".$accession_number."'\n";
            print STDERR "$subname: \$faa1 = '\n$faa1'\n";

            if ( 0 && $outfile) {
                open my $OUTFH, '>', $outfile
                    or croak "Can't open '$outfile': $OS_ERROR";
                print {$OUTFH} $faa1
                    or croak "Can't write to '$outfile': $OS_ERROR";
                close $OUTFH
                    or croak "Can't close '$outfile': $OS_ERROR";
            }

            Annotate_Verify::check_old_annotation( $accession_number, $faa1);
       }

   }

} # sub process_list3


=head2 list_dir_files

List the files with given pattern in a folder

=cut

sub list_dir_files {
    my ($list_fn, $ptn) = @_;

    my $debug = 0 && $debug_all;
    my $subname = 'Annotate_misc::list_dir_files';

    $debug && print STDERR "$subname: \$list_fn=$list_fn\n";
    $debug && print STDERR "$subname: \$ptn=$ptn\n";
    my @files = ();
    my $accs = [];
    if (!-d $list_fn) {
        croak("$subname: Couldn't locate accession file/directory: $list_fn: $OS_ERROR");
    }

    # if input -l file is directory
    opendir(DIR, $list_fn)
           or croak("$subname: Couldn't open dir $list_fn: $OS_ERROR");
    @files = sort readdir(DIR)
           or croak("$subname: Couldn't read dir $list_fn: $OS_ERROR");
    closedir(DIR)
           or croak("$subname: Couldn't close dir $list_fn: $OS_ERROR");
    $debug && print STDERR "$subname: \@files='@files'\n";

    for (my $f = 0; $f<=$#files; $f++) {
            my ($number, $acc);
            my $file = $files[$f];
            chomp $file;
            if ($file !~ /$ptn/) { # Keep the gbk files
#            if ($file !~ /^\s*([^\s]+)(\.(gb|gbk|genbank))\s*$/) { # Keep the gbk files
               $debug && print STDERR "$subname: skipping file: '$file'\n";
               next;
            } else {
                $number = $#{$accs}+1;
                $acc = "$list_fn/$file";
#                print STDERR "\$1=\'$1\'\n";
            }
            push @$accs, [$number, $acc];
    }
    $debug && print STDERR "$subname: \@\$accs=".Dumper($accs)."\n";

    return $accs;
} # sub list_dir_files


=head2 Usage

Print the useage according to calling sub
 vipr_mat_peptide.pl:     for deployment
 vipr_mat_peptide_dev.pl: for testing

=cut

sub Usage {
    my ($source, $exe_dir) = @_;

    my $debug = 0 && $debug_all;
    my $subname = 'Annotate_misc::Usage';

    my $usages = {};
    $usages = {
                'vipr_mat_peptide.pl' =>
	"$source Ver$Annotate_Def::VERSION
Usage:  -d directory to find the input genome file
        -i name of the input genbank file
        -l name of input folder",
                'vipr_mat_peptide_dev.pl' =>
"$source Ver$VERSION
Usage:  -d directory to find the input genome file
        -i name of the input genbank file
        -l name of input folder,
           or the name of a text file of accessions, and genbank file to be obtained from a database (MySQL)",
              };

    my $example = "
    E.g.: $source -d ./ -i NC_001477.gb
    E.g.: $source -d ./ -l all_genomes/ \n\n";

    my $usage = "$subname: default, need input for calling program, production or development";
    if (exists($usages->{$source})) {
        $usage = $usages->{$source};
        $usage .= $example;
    }

    # Get the list of approved species in each viral family and their RefSeq
    my $refseq_list = Annotate_Def::get_refseq_acc( undef, $exe_dir);
    $debug && print STDERR "$subname: \$refseq_list=".Dumper($refseq_list)."\n";
    $usage .= $refseq_list;

    print STDERR "$subname: \$usage=\n".Dumper($usage)."\n";
    return $usage . "\n";
} # sub Usage


1;

