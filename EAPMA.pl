#!/usr/bin/perl -w
use strict;
use Getopt::Long;

my $version_num = "dev3"; 
# Development begun Dec 13, 2013 MJA .. dev2 begun Jan 6, 2014
# dev 3 on March 4, 2014

my $usage = "EAPMA.pl version $version_num
Usage: EAPMA.pl [options] [alignments.bam] [genome.fasta] [chr:start-stop]

Dependencies: 
samtools
RNALfold

Options:
--strand : limit analysis to indicated strand \(+ or -\) of genome
--mature : annotated/hypothesized mature miRNA sequence
--help : print this message and quit
--version : print version and quit

Documentation: perldoc EAPMA.pl
";

# If no arguments, print help and quit
unless($ARGV[0]) {
    print "$usage";
    exit;
}

# Initiialize options
my $strand = "b";
my $mature = '';
my $help = '';
my $version = '';

# Get ye options
GetOptions ('strand=s' => \$strand,
	    'mature=s' => \$mature,
	    'help' => \$help,
	    'version' => \$version);

# If version or help, act accordingly
if($version) {
    print "EAPMA.pl version $version_num\n";
    exit;
}
if($help) {
    print "$usage";
    exit;
}

# Check for required samtools installation
(open(SAMCHECK, "which samtools |")) || die "\nAbort: Failed to check for samtools installation\n";
my $samcheck = <SAMCHECK>;
chomp $samcheck;
close SAMCHECK;
unless ($samcheck =~ /samtools$/) {
    die "\nAbort: samtools installation not found. Please install samtools to your PATH and try again\n";
}

# Check for required RNALfold installation
(open(RNALCHECK, "which RNALfold |")) || die "\nAbort: Failed to check for RNALfold installation\n";
my $rnalcheck = <RNALCHECK>;
chomp $rnalcheck;
close RNALCHECK;
unless( $rnalcheck =~ /RNALfold$/) {
    die "\nAbort: RNALfold installation not found. Please install RNALfold to your PATH and try again\n";
}

# Validate option --strand
unless(($strand eq "b") or ($strand eq "+") or ($strand eq "-")) {
    die "\nAbort: Option --strand is invalid. Must be either +, -, or b.\n";
}

# Validate option --mature
my $mature_ok;
if($mature) {
    # upppercase
    $mature_ok = uc $mature;
    # change T to U
    $mature_ok =~ s/T/U/g;
    # Verify
    unless($mature_ok =~ /^[AUCG]+$/) {
	die "\nAbort: Option --mature is invalid. It must be a string containing only AUTGCautgc characters.\n";
    }
}

# Validate genome and get faidx
my $genomefile;
if($ARGV[-2]) {
    if(-r $ARGV[-2]) {
	$genomefile = $ARGV[-2];
    } else {
	die "Genome file $ARGV[-2] was not readable. Abort.\n";
    }
} else {
    die "Genome file was not found in command line. Abort.\n";
}
my $expected_faidx = "$genomefile" . "\.fai";
unless(-r $expected_faidx) {
    print STDERR "\nAttempting to create  required genome index file $expected_faidx using samtools ..";
    system "samtools faidx $genomefile";
    if(-r $expected_faidx) {
	print STDERR " Done\n";
    } else {
	print STDERR " Failed! Abort\n";
	exit;
    }
}

# Validate bam
my $bamfile;
my $bam_check;
if($ARGV[-3]) {
    if($ARGV[-3] =~ /\.bam$/) {
	if(-r $ARGV[-3]) {
	    $bamfile = $ARGV[-3];
	    $bam_check = validate_bam($bamfile,$expected_faidx);
	    unless($bam_check) {
		exit;
	    }
	} else {
	    die "Abort: bamfile $ARGV[-3] was not readable\n";
	}
    } else {
	die "Abort: bamfile $ARGV[-3] did not end in .bam\n";
    }
} else {
    die "Abort: No bamfile was specified on the command line\n";
}

# Validate coordinates
my $co;
if($ARGV[-1]) {
    $co = $ARGV[-1];
} else {
    die "Abort: Coordinates not found on the command line\n";
}
my $co_check = check_coordinates ($co,$expected_faidx);
unless($co_check) {
    exit;
}

# Get the sense strand sequence
my $sense_seq = get_sense_seq($genomefile,$co);


# Get the rev comp, unless --strand was "+"
my $revcomp_seq;
unless($strand eq "+") {
    $revcomp_seq = reverse $sense_seq;
    $revcomp_seq =~ tr/AUGC/UACG/;
}

# Initial information for user
print "\nEAPMA.pl version $version_num\n";
print "Date: ";
print `date`;
print "Hostname: ";
print `hostname`;
print "Working Directory: ";
print `pwd`;
print "\nAlignments: $ARGV[-3]\n";
print "Genome: $ARGV[-2]\n";
print "Locus: $ARGV[-1]\n";
print "Strand: ";
if($strand eq "b") {
    print "Both\n";
} else {
    print "$strand\n";
}
print "User-supplied mature miRNA: ";
if($mature) {
    print "$mature\n";
} else {
    print "Not provided\n";
}

# sense first
unless($strand eq "-") {
    print "\n\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\n\nPLUS STRAND ANALYSIS\n\n";
    master($sense_seq,$bamfile,$mature_ok,$co,"+");
}
# revcomp second
unless($strand eq "+") {
    print "\n\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\n\nMINUS STRAND ANALYSIS\n\n";
    master($revcomp_seq,$bamfile,$mature_ok,$co,"-");
}
    
################

sub master {
    my($seq,$bamfile,$mature,$query,$strand) = @_;

    my @scores = ();
    
    my @m_scores = ();
    
    my $x; 

    my $user_mir;
    my $most_abun;
    
    # Obtain the lowest free energy structure per RNALfold
    my $struc_results = get_struc($seq);
    ## $struc_results is either 0 for no struc found, or tab-delimited brax, dg, local start
    
    my $mod_seq;
    
    my %read_hash = ();
    my $ma_star;
    my $user_star;
    
    if($struc_results) {
	$scores[0] = 1;
	# TEST
	#print STDERR "\$struc_results is $struc_results\n";
    
	# Parse the coordinates of the structure
	my $mod_query = get_mod_query($struc_results,$query,$strand);
	# TEST
	#print STDERR "\$mod_query is $mod_query\n";
	
	# Report the location of the structure
	print "BEST STRUCTURE: $mod_query $strand\n\n";
	
	# Get a corresponding trimmed version of the sequence
	$mod_seq = get_mod_seq($query,$mod_query,$seq,$strand);
	# TEST
	#print STDERR "\$mod_seq is $mod_seq\n";
	
	# Get info for all reads that are fully aligned in the query region on designated strand
	my @sam = get_sam($bamfile,$mod_query,$strand);
	
	## If no reads at all, do not proceed.
	if($sam[0]) {
	    $scores[1] = 1;
	    # TEST
	    #print STDERR "\$sam[0] is $sam[0]\n";
	    #print STDERR "\$sam[-1] is $sam[-1]\n";
	    
	    
	    # Get the rep-norm total abundance, and the number of uniquely aligned reads to the locus
	    my($rep_norm,$uniques) = check_rep_counts(@sam);
	    $scores[2] = sprintf("%.1f",$rep_norm);
	    $scores[3] = $uniques;
	    # TEST
	    #print STDERR "\$scores[2] is $scores[2]\n";
	    #print STDERR "\$scores[3] is $scores[3]\n";
	    
	    # Compress into hash.  Keys are 1-based starts, relative to mod_query _ length, values are frequencies
	    %read_hash = get_read_hash(\@sam,\$mod_query,\$strand);
	    # TEST
	    #print STDERR "\%read_hash\n";
	    #my $tt;
	    #my $uu;
	    #while (($tt,$uu) = each %read_hash) {
		#print STDERR "\t$tt\t$uu\n";
	    #}
	    
	    # Print size distribution of alignments for the user
	    print_align_summary(\%read_hash);
	    
	    # If mature is included, get its position(s), as the 1-based start position _ length
	    my @mature_match = ();
	    if($mature) {
		@mature_match = check_mature_match($mature,$mod_seq);
		if($mature_match[0]) {
		    $scores[4] = scalar @mature_match;
		    ## TEST
		    #print STDERR "\@mature_match is @mature_match\n";
		    
		} else {
		    $scores[4] = 0;
		}
	    } else {
		$scores[4] = -1;
	    }
	    
	    #############
	    # de novo analysis, indpendent of @mature_match
	    # Simply analyzes the most abundant read
	    
	    # Find the most abundant position
	    $most_abun = get_most_abun(%read_hash);
	    # TEST
	    #print STDERR "\$most_abun is $most_abun\n";
	    
	    # Get the brackets
	    my $ma_brac = get_brax_subset($most_abun,$struc_results);
	    # TEST
	    #print STDERR "\$ma_brac is $ma_brac\n";
	    
	    # Pairing of ma_brac .. determine arm.  0 is loop-spanning or no pairs, 1 is 5p arm, 2 is 3p arm
	    $scores[5] = score_brac_pairing($ma_brac);
	    # TEST
	    #print STDERR "\$scores[5] is $scores[5]\n";
	    
	    # To proceed to try and find star, there must be six or fewer unpaired nts in the mature, not counting the 3'-most 2 nts (overhangs in miR/miR* duplex)
	    $scores[6] = count_duplex_unpairs($ma_brac);
	    # TEST
	    #print STDERR "\$scores[6] is $scores[6]\n";
	    
	    # Get the star, if the ma_brac is kosher .. $scores[5] is not zero, and $scores[6] is <= 6
	    # $ma_star;  ## left-most_length, like $most_abun
	    if(($scores[5]) and ($scores[6] <= 6)) {
		$ma_star = get_star($most_abun,$struc_results,$scores[5]);
		# TEST
		#print STDERR "\$ma_star is $ma_star\n";
	    }
	    
	    # $scores[7] simply indicates whether or not the star was able to be computationally deduced
	    if($ma_star) {
		$scores[7] = 1;
	    } else {
		$scores[7] = 0;
	    }
	    # TEST
	    #print STDERR "\$scores[7] is $scores[7]\n";
	    
	    # analyze the miR/miR* duplex to find the total number of assym nts.
	    my $assym = -1;

	    if($ma_star) {
		$assym = check_duplex_struc($most_abun,$ma_star,$struc_results,$scores[5]);
	    }
	    $scores[8] = $assym;

	    # TEST
	    #print STDERR "\$scores[8] is $scores[8] assym\n";
	    
	    # Identify the boundaries of the stem in which the miR/miR* duplex exists.
	    my $stem_pos;
	    my $max_buffer;
	    my $star_exp = 0;
	    if($ma_star) {
		$stem_pos = get_stem_pos($most_abun,$ma_star,$struc_results,$scores[5]);
		# in the format 5pstart-5pstop,3pstart-3pstop
		# TEST
		#print STDERR "\$stem_pos is $stem_pos\n";
		
		# Determine max buffer. Based on our knowledge of plant MIR processing, we need ~ 15nts of structure on at least one of the two sides of the miR/miR* duplex
		$max_buffer = get_max_buffer($most_abun,$ma_star,$stem_pos,$scores[5]);
		# TEST
		#print STDERR "\$max_buffer is $max_buffer\n";
		
		# Get freq of star 
		if(exists($read_hash{$ma_star})) {
		    $star_exp = $read_hash{$ma_star};
		}
		$scores[9] = $max_buffer;
	    } else {
		$scores[9] = -1;
	    }
	    
	    $scores[10] = $star_exp;
	    $scores[11] = $read_hash{$most_abun}; ## you know it will be defined as it is the most abundant read,

            # Get total expression level of most_abun and its star
	    $scores[12] = $scores[11] + $star_exp;
	    
	    # Get precision
	    my $total_reads = scalar @sam;
	    $scores[13] = sprintf("%.3f",($scores[12] / $total_reads));
	    
	    # TEST
	    #print STDERR "\$scores[9] is $scores[9]\n";
	    #print STDERR "\$scores[10] is $scores[10]\n";
	    #print STDERR "\$scores[11] is $scores[11]\n";
	    #print STDERR "\$scores[12] is $scores[12]\n";
	    #print STDERR "\$scores[13] is $scores[13]\n";
	    
	    # Score if miR exists (in de novo, of course it does, but need this to be consistent with the user-supplied route
	    $scores[14] = 1;
	    # Score if miR is >= abundance of star. Again, for de novo, of course it is, but need to do this to be consistent with user-supplied route
	    $scores[15] = 1;
	    
	    
	    ################### user-supplied mature, if applicable
	    if($scores[4] > 0) {
		# recall that scores[4] is the number of times that the user-supplied mature sequence occurs within $mod_seq.
		# If there are multiple matches, quietly select one to analyze -- most alignments, or if tie, arbitrary.
		if($scores[4] > 1) {
		    $user_mir = select_user_mir(\@mature_match,\%read_hash);
		} else {
		    $user_mir = $mature_match[0];
		}
		# TEST
		#print STDERR "\$user_mir is $user_mir\n";
		
		# If the $user_mir is the same as $most_abun, then no need to re-analyze.
		if ($user_mir eq $most_abun) {
		    @m_scores = @scores;
		    if($ma_star) {
			$user_star = $ma_star;
		    }
		} else {
		    # populate shared parts
		    $m_scores[0] = $scores[0];
		    $m_scores[1] = $scores[1];
		    $m_scores[2] = $scores[2];
		    $m_scores[3] = $scores[3];
		    $m_scores[4] = $scores[4];
		    
		    # Need to re-analyze here .. user_mir is not the most abundant read
		    # Get the brackets
		    my $user_brac = get_brax_subset($user_mir,$struc_results);
		    # TEST
		    #print STDERR "\$user_brac is $user_brac\n";
		    
		    # Pairing of ma_brac .. determine arm.  0 is loop-spanning or no pairs, 1 is 5p arm, 2 is 3p arm
		    $m_scores[5] = score_brac_pairing($user_brac);
		    # TEST
		    #print STDERR "\$m_scores[5] is $m_scores[5]\n";
		    
		    # To proceed to try and find star, there must be six or fewer unpaired nts in the mature, not counting the 3'-most 2 nts (overhangs in miR/miR* duplex)
		    $m_scores[6] = count_duplex_unpairs($user_brac);
		    # TEST
		    #print STDERR "\$m_scores[6] is $m_scores[6]\n";
		    
		    # Get the star, if the ma_brac is kosher .. $m_scores[5] is not zero, and $m_scores[6] is <= 6
		    #$user_star;  ## left-most_length, like $most_abun
		    if(($m_scores[5]) and ($m_scores[6] <= 6)) { 
			$user_star = get_star($user_mir,$struc_results,$m_scores[5]);
			# TEST
			#print STDERR "\$user_star is $user_star\n";
		    }
		    
		    # $m_scores[7] simply indicates whether or not the star was able to be computationally deduced
		    if($user_star) {
			$m_scores[7] = 1;
		    } else {
			$m_scores[7] = 0;
		    }
		    # TEST
		    #print STDERR "\$m_scores[7] is $m_scores[7]\n";
		    
		    # analyze the miR/miR* duplex to find the total number of assym nts.
		    $assym = -1;
		    
		    if($user_star) {
			$assym = check_duplex_struc($user_mir,$user_star,$struc_results,$m_scores[5]);
		    }
		    $m_scores[8] = $assym;

		    # TEST
		    #print STDERR "\$m_scores[8] is $m_scores[8] assym\n";
		    
		    # Identify the boundaries of the stem in which the miR/miR* duplex exists.
		    $stem_pos = '';
		    $max_buffer = '';
		    $star_exp = 0;
		    if($user_star) {
			$stem_pos = get_stem_pos($user_mir,$user_star,$struc_results,$m_scores[5]);
			# in the format 5pstart-5pstop,3pstart-3pstop
			# TEST
			#print STDERR "\$stem_pos is $stem_pos\n";
			
			# Determine max buffer. Based on our knowledge of plant MIR processing, we need ~ 15nts of structure on at least one of the two sides of the miR/miR* duplex
			$max_buffer = get_max_buffer($user_mir,$user_star,$stem_pos,$m_scores[5]);
			# TEST
			#print STDERR "\$max_buffer is $max_buffer\n";
			
			# Get freq of star 
			if(exists($read_hash{$user_star})) {
			    $star_exp = $read_hash{$user_star};
			}
			$m_scores[9] = $max_buffer;
		    } else {
			$m_scores[9] = 0;
		    }
		    $m_scores[10] = $star_exp;
		    
                    # And oh yeah, is the user_mir even expressed?
		    if(exists($read_hash{$user_mir})) {
			$m_scores[11] = $read_hash{$user_mir};
		    } else {
			$m_scores[11] = 0;
		    }

		    $m_scores[12] = $m_scores[11] + $star_exp;
		    
		    # Get precision
		    
		    $m_scores[13] = sprintf("%.3f",($m_scores[12] / $total_reads));
		    
		    # TEST
		    #print STDERR "\$m_scores[9] is $m_scores[9]\n";
		    #print STDERR "\$m_scores[10] is $m_scores[10]\n";
		    #print STDERR "\$m_scores[11] is $m_scores[11]\n";
		    #print STDERR "\$m_scores[12] is $m_scores[12]\n";
		    #print STDERR "\$m_scores[13] is $m_scores[13]\n";
		    
		    # Was user mir sequenced at all?
		    if($m_scores[11]) {
			$m_scores[14] = 1;
		    } else {
			$m_scores[14] = 0;
		    }
		    
		    # Is user mir >= abun of user star?
		    if($m_scores[11] >= $m_scores[10]) {
			$m_scores[15] = 1;
		    } else {
			$m_scores[15] = 0;
		    }
		}
	    }
	} else {
	    ## no reads found.
	    $scores[1] = 0;
	}
    } else {
	## no structure at all found
	$scores[0] = 0;
    }
    
    ## Compile the de-novo score
    print "DE NOVO ANALYSIS:\n";    
    
    if($scores[0] == 0) {
	print "\*\*\* SUMMARY\n";
	print "\tOVERALL_SCORE:0\n";
	print "\tOVERALL_VERDICT:FAIL:NO_STRUCTURE\n";
    } elsif ($scores[1] == 0) {
	print "\*\*\* SUMMARY\n";
	print "\tOVERALL_SCORE:0\n";
	print "\tOVERALL_VERDICT:FAIL:NO_ALIGNMENTS\n";
    } else {
	score_it(@scores);
	# if master, score
	if($scores[4] > 0) {
	    print "\nUSER-SUPPLIED MATURE ANALYSIS:\n";
	    if($user_mir eq $most_abun) {
		print "\tUser-supplied mature miRNA sequence was IDENTICAL to the de-novo discovered most abundant small RNA\n";
	    } else {
		print "\tUser-supplied mature miRNA sequence was DIFFERENT THAN the de-novo discovered most abundant small RNA\n";
	    }
	    score_it(@m_scores);
	}
	# print sequence and brackets
	print "\n$mod_seq\n";
	my $just_brax = $struc_results;
	$just_brax =~ s/\t.*$//g;
	print "$just_brax\n";

	# Define the "special" lines, and add the special positions into the read_hash if they are not there
	my %specials = ();
	if($most_abun) {
	    push(@{$specials{$most_abun}}, "dn_miRNA");
	    unless(exists($read_hash{$most_abun})) {
		$read_hash{$most_abun} = 0;
	    }
	}
	if($ma_star) {
	    push(@{$specials{$ma_star}}, "dn_star");
	    unless(exists($read_hash{$ma_star})) {
		$read_hash{$ma_star} = 0;
	    }
	}
	if($user_mir) {
	    push(@{$specials{$user_mir}}, "u_miRNA");
	    unless(exists($read_hash{$user_mir})) {
		$read_hash{$user_mir} = 0;
	    }
	}
	if($user_star) {
	    push(@{$specials{$user_star}}, "u_star");
	    unless(exists($read_hash{$user_star})) {
		$read_hash{$user_star} = 0;
	    }
	}
	
        # sort the lines by left-most positions
	my @sorted_rhkeys = get_sorted_rh_keys(\%read_hash);
	
	
	# Output line by line
	my $sequence;
	my @srhk_fields = ();
	my $space_char;
	my $i;
	foreach my $srhk (@sorted_rhkeys) {
	    @srhk_fields = split ("_", $srhk);
	    if(exists($specials{$srhk})) {
		if($read_hash{$srhk} == 0) {
		    $space_char = "x";
		} else {
		    $space_char = "\*";
		}
	    } else {
		$space_char = "\.";
	    }
	    for ($i = 1; $i < $srhk_fields[0]; ++$i) {
		print "$space_char";
	    }
	    $sequence = substr($mod_seq,($srhk_fields[0] - 1),$srhk_fields[1]);
	    print "$sequence";
	    for ($i = ($srhk_fields[0] + $srhk_fields[1]); $i <= (length $mod_seq); ++$i) {
		print "$space_char";
	    }
	    print " l=$srhk_fields[1] a=$read_hash{$srhk}";
	    if(exists($specials{$srhk})) {
		print " @{$specials{$srhk}}\n";
	    } else {
		print "\n";
	    }
	}
    }
}

sub get_sorted_rh_keys {
    my($hash) = @_; ## passed by ref
    my %new = ();
    my $key;
    my @fields = ();
    while(($key) = each %$hash) {
	@fields = split ("_", $key);
	$new{$key} = $fields[0];
    }
    my @sorted = sort { $new{$a} <=> $new{$b} } keys %new;
    return @sorted;
}


sub print_align_summary {
    my($read_hash) = @_;  ## passed by reference
    my %freq = ();
    my $key;
    my $freq;
    my $count;
    my @fields = ();
    while(($key,$count) = each %$read_hash) {
	@fields = split ("_", $key);
	if($fields[1] < 20) {
	    $freq{'small'} += $count;
	} elsif ($fields[1] > 24) {
	    $freq{'large'} += $count;
	} else {
	    $freq{$fields[1]} += $count;
	}
    }
    print "RNA_SIZE\tALIGNMENTS\n"; 
    if(exists($freq{'small'})) {
	print "<20\t$freq{'small'}\n";
    } else {
	print "<20\t0\n";
    }
    for (my $i = 20; $i <= 24; ++$i) {
	if(exists($freq{$i})) {
	    print "$i\t$freq{$i}\n";
	} else {
	    print "$i\t0\n";
	}
    }
    if(exists($freq{'large'})) {
	print ">24\t$freq{'large'}\n";
    } else {
	print ">24\t0\n\n";
    }
}
	
sub score_it {
    my(@in) = @_;
    my @fails = ();
    my $overall_score = 0;
    my $exp_weight = sprintf("%.4f",(0.5 / 6));
    my $str_weight = sprintf("%.4f",(0.5 / 5));
    my $this_score;
    
    print "\*\*\* EXPRESSION-BASED EVALUATION WEIGHTED AT $exp_weight each\n";
    print "\tSCORE\tITEM:VALUE\n";
    
    # [2] : m-map corrected reads .. 0-4 is 0, 5-9 is 0.25, 10-49 is 0.5, 50-99 is 0.75, >= 100 is 1
    if($in[2] < 5) {
	$this_score = 0;
    } elsif ($in[2] < 10) {
	$this_score = 0.25;
    } elsif ($in[2] < 50) {
	$this_score = 0.5;
    } elsif ($in[2] < 100) {
	$this_score = 0.75;
    } else {
	$this_score = 1;
    }
    print "\t$this_score\tMULTI-MAPPED_CORRECTED_READ_TOTAL:$in[2]\n";
    $overall_score += ($exp_weight * $this_score);


    # [3] : uniquely mapped reads .. 0 for 0, 1 for 1 or more.
    if($in[3] > 0) {
	$this_score = 1;
    } else {
	$this_score = 0;
    }
    print "\t$this_score\tUNIQUELY_MAPPED_READS:$in[3]\n";
    $overall_score += ($exp_weight * $this_score);
    
    # [10] : reads of star .. 0 is 0, 1-5 is 0.5, 6 or more is 1.
    if($in[10] >= 6) {
	$this_score = 1;
    } elsif (($in[10] >= 1) and ($in[10] <= 5)) {
	$this_score = 0.5;
    } else {
	$this_score = 0;
	push(@fails,"NO_STAR_EXPRESSED");
    }
    print "\t$this_score\tSTAR_READS:$in[10]\n";
    $overall_score += ($exp_weight * $this_score);
    
    # [11] : reads of mature miR .. 0-4 is 0, 5-9 is 0.25, 10-49 is 0.5, 50-99 is 0.75, >= 100 is 1 .. 0 is fatal
    if(($in[11] >= 5) and ($in[11] <= 9)) {
	$this_score = 0.25;
    } elsif (($in[11] >= 10) and ($in[11] <= 49)) {
	$this_score = 0.5;
    } elsif (($in[11] >= 50) and ($in[11] <= 99)) {
	$this_score = 0.75;
    } elsif ($in[11] >= 100) {
	$this_score = 1;
    } else {
	$this_score = 0;
	push(@fails,"LOW_MATURE_EXPRESSION");
    }
    print "\t$this_score\tmiRNA_READS:$in[11]\n";
    $overall_score += ($exp_weight * $this_score);
    
    # [13] : precision ... as is.
    print "\t$in[13]\tPRECISION:$in[13]\n";
    $overall_score += ($exp_weight * $in[13]);
    if($in[13] < 0.25) {
	push(@fails,"IMPRECISE");
    }
    
    # [15] : if miR abun >= star_abun . as is (1 or 0)
    print "\t$in[15]\tMIR_GTEQ_STAR:$in[15]\n";
    $overall_score += ($exp_weight * $in[15]);
    unless($in[15]) {
	push(@fails,"STAR_GT_MIR");
    }

    print "\*\*\* STRUCTURE-BASED EVALUATION WEIGHTED AT $str_weight each\n";
    print "\tSCORE\tITEM:VALUE\n";

    # [5] : self-pairing of miRNA .. 0 for 0, 1 for anything else (1 or 2)
    my $arm;
    if($in[5] == 0) {
	$this_score = 0;
	push(@fails,"MIR_NOT_ON_STEM");
	$arm = "NA";
    } elsif ($in[5] == 1) {
	$this_score = 1;
	$arm = "5p";
    } elsif ($in[5] == 2) {
	$this_score = 1;
	$arm = "3p";
    }
    print "\t$this_score\tMIR_ARM:$arm\n";
    $overall_score += ($str_weight * $this_score);
    
    # [6] : miR unpaired nts .. 1 for 0-3, 0.5 for 4, 0.25 for 5, 0 for 6 or more.
    if($in[6] <= 3) {
	$this_score = 1;
    } elsif ($in[6] == 4) {
	$this_score = 0.5;
    } elsif ($in[6] == 5) {
	$this_score = 0.25;
    } else {
	$this_score = 0.25;
	push(@fails,"GT6_UP_MIR");
    }
    print "\t$this_score\tMIR_UNPAIRED:$in[6]\n";
    $overall_score += ($str_weight * $this_score);

    # [7] : miR* able to be deduced. as is .. either 1 or 0.
    print "\t$in[7]\tSTAR_COMPUTABLE:$in[7]\n";
    $overall_score += ($str_weight * $in[7]);
    unless($in[7]) {
	push(@fails,"STAR_NOT_COMPUTABLE");
    }
    
    # [8] : total assymetric nts. in miR/miR* duplex. 0-1 is 1, 2 is 0.5, 3 is 0.25, >= 4 is 0. 0 is fatal.
    if(($in[8] == 0) or ($in[8] == 1)) {
	$this_score = 1;
    } elsif ($in[8] == 2) {
	$this_score = 0.5;
    } elsif ($in[8] == 3) {
	$this_score = 0.25;
    } elsif ($in[8] > 3) {
	$this_score = 0;
	push(@fails,"TOO_MANY_BULGES");
    } elsif ($in[8] == -1) {
	$this_score = 0;
    }
    print "\t$this_score\tN_BULGES_DUPLEX:$in[8]\n";
    $overall_score += ($str_weight * $this_score);
    
    # [9] : buffer size .. 1 if 15 or more, 0.25 if 13 or 14, 0 if less than 13.
    if($in[9] >= 15) {
	$this_score = 1;
    } elsif (($in[9] == 13) or ($in[9] == 14)) {
	$this_score = 0.25;
    } else {
	$this_score = 0;
#	push(@fails,"INSUFFICIENT_BUFFER");  ## Decided against failing loci for insufficient buffer. Not in the Meyers et al. criteria.
    }
    print "\t$this_score\tMAX_STEM_BUFFER:$in[9]\n";
    $overall_score += ($str_weight * $this_score);
    
    my $overall_rounded_score = sprintf("%.3f",$overall_score);
    
    print "\*\*\* SUMMARY\n";
    print "\tOVERALL_SCORE:$overall_rounded_score\n";
    print "\tOVERALL_VERDICT:";
    if($fails[0]) {
	print "FAIL:@fails\n";
    } else {
	print "PASS\n";
    }
}

sub check_rep_counts {
    my(@sam) = @_;
    my $rep_norm = 0;
    my $uniques = 0;
    my $this_rep;
    foreach my $samline (@sam) {
	if($samline =~ /\tX0:i:(\d+)/) {
	    $this_rep = 1 / $1;
	    $rep_norm += $this_rep;
	    if($this_rep == 1) {
		++$uniques;
	    }
	} elsif ($samline =~ /\tXX:i:(\d+)/) {
	    $this_rep = 1 / $1;
	    $rep_norm += $this_rep;
	    if($this_rep == 1) {
		++$uniques;
	    }
	}
    }
    return($rep_norm,$uniques);
}
	

sub select_user_mir {
    my($mature_match,$read_hash) = @_; ## passed by reference,, array and hash
    my $max;
    my $max_mat;
    foreach my $mat (@$mature_match) {
	if($max_mat) {
	    if(exists($$read_hash{$mat})) {
		if($$read_hash{$mat} > $max) {
		    $max = $$read_hash{$mat};
		    $max_mat = $mat;
		}
	    }
	} else {
	    ## First time enter no matter what
	    if(exists($$read_hash{$mat})) {
		$max = $$read_hash{$mat};
		$max_mat = $mat;
	    } else {
		$max = 0;
		$max_mat = $mat;
	    }
	}
    }
    return $max_mat;
}
    

sub get_max_buffer {
    my($mir,$star,$stem_pos,$strand) = @_;
    # TEST
    #print STDERR "\tInput to get_max_buffer is mir $mir star $star stem_pos $stem_pos strand $strand\n";
    my @m = split ("_", $mir);
    my @s = split ("_", $star);
    my $mir_end = $m[0] + $m[1] - 1;
    my $star_end = $s[0] + $s[1] - 1;
    #TEST
    #print STDERR "\tmir_end $mir_end star_end $star_end\n";
    my $base_5;
    my $loop_5;
    my $loop_3;
    my $base_3;
    if($stem_pos =~ /^(\d+)-(\d+)\,(\d+)-(\d+)$/) {
	$base_5 = $1;
	$loop_5 = $2;
	$loop_3 = $3;
	$base_3 = $4;
    } else {
	return 0;
    }
    # TEST
    #print STDERR "\tbase_5 $base_5 loop_5 $loop_5 loop_3 $loop_3 base_3 $base_3\n";
    my $low;
    my $high;
    if($strand == 1) {
	# miR is on the 5p arm
	# TEST
	#print STDERR "\t5p arm detected\n";
	$low = 0.5 * (($m[0] - $base_5) + ($base_3 - $star_end));
	$high = 0.5 * (($loop_5 - $mir_end) + ($s[0] - $loop_3));
	# TEST
	#print STDERR "\tlow $low high $high\n";
    } elsif ($strand == 2) {
	# miR is on the 3p arm
	# TEST
	#print STDERR "\t3p arm detected\n";
	$low = 0.5 * (($s[0] - $base_5) + ($base_3 - $mir_end));
	$high = 0.5 * (($loop_5 - $star_end) + ($m[0] - $loop_3));
	# TEST
	#print STDERR "\tlow $low high $high\n";
    } else {
	return 0;
    }
    if($low >= $high) {
	# TEST
	#print STDERR "\treturned low of $low\n";
	return $low;
    } else {
	# TEST
	#print STDERR "\treturned high of $high\n";
	return $high;
    }
}
    

sub get_stem_pos {
    my($mir,$star,$struc_results,$strand) = @_;
    my @m = split ("_", $mir);
    my @s = split ("_", $star);
    my @st = split ("\t",$struc_results);
    my $mir_end = $m[0] + $m[1] - 1;
    my $star_end = $s[0] + $s[1] - 1;
    my $five_base;
    my $five_loop;
    my $three_base;
    my $three_loop;
    if($strand == 1) {
	$five_base = $m[0];
	$five_loop = $mir_end;
	$three_loop = $s[0];
	$three_base = $star_end;
    } elsif ($strand == 2) {
	$five_base = $s[0];
	$five_loop = $star_end;
	$three_loop = $m[0];
	$three_base = $mir_end;
    } else {
	return 0;
    }
    my %lr = get_lr($st[0]);
    my %rl = get_rl($st[0]);


    my $i;
    
    # Find the ends ..
    # first, 5p_start
    my $last_ok = $five_base; ## not necessarily paired
    for($i = $five_base; $i > 0; --$i) {
	if(exists($rl{$i})) {
	    last;
	} elsif (exists($lr{$i})) {
	    $last_ok = $i;
	}
    }
    my $five_base_min = $last_ok;
    
    # now, 5p_loop_max
    $last_ok = $five_loop;
    for($i = $five_loop; $i < $three_loop; ++$i) {
	if(exists($rl{$i})) {
	    last;
	} elsif (exists($lr{$i})) {
	    $last_ok = $i;
	}
    }
    my $five_loop_max = $last_ok;
    
    # 3p_loop_min
    $last_ok = $three_loop;
    for($i = $three_loop; $i > $five_loop; --$i) {
	if(exists($lr{$i})) {
	    last;
	} elsif (exists($rl{$i})) {
	    $last_ok = $i;
	}
    }
    my $three_loop_min = $last_ok;
    
    # 3p_base_max
    $last_ok = $three_base;
    for($i = $three_base; $i < (length $st[0]); ++$i) {
	if(exists($lr{$i})) {
	    last;
	} elsif (exists($rl{$i})) {
	    $last_ok = $i;
	}
    }
    my $three_base_max = $last_ok;
    
    # Consensus
    my $start_5;
    my $stop_5;
    my $start_3;
    my $stop_3;
    
    # Safeguard against really aberrant structures
    
    if (($lr{$five_base_min}) and ($three_base_max) and ($lr{$five_base_min} <= $three_base_max)) {
	$start_5 = $five_base_min;
	$stop_3 = $lr{$five_base_min};
    } elsif (($rl{$three_base_max}) and ($three_base_max)) {
	$start_5 = $rl{$three_base_max};
	$stop_3 = $three_base_max;
    } else {
	return 0;
    }
    
    if(($lr{$five_loop_max}) and ($three_loop_min) and ($lr{$five_loop_max} <= $three_loop_min)) {
	$stop_5 = $rl{$three_loop_min};
	$start_3 = $three_loop_min;
    } elsif (($five_loop_max) and ($lr{$five_loop_max})) {
	$stop_5 = $five_loop_max;
	$start_3 = $lr{$five_loop_max};
    } else {
	return 0;
    }
    my $out = "$start_5" . "-" . "$stop_5" . "," . "$start_3" . "-" . "$stop_3";  
    return $out;
}
	
    
sub check_duplex_struc {
    my($mir,$star,$struc_result,$arm) = @_;
    
    # Parse mir and star
    my @ma = split ("_",$mir);  ## [0] is left-most, [1] is length
    my $mir_end = $ma[0] + $ma[1] - 1;
    my @sa = split ("_",$star); 
    my $star_end = $sa[0] + $sa[1] - 1;
    
    # Parse $struc_results
    my @st = split ("\t", $struc_result);  ## [0] is brax
    
    # Initialize counters
    my $bul_n = 0;
    my $bul_nts = 0;
    my $ail_n = 0;
    my $ail_nts = 0;
    
    # Get left-right hash
    my %lr = get_lr($st[0]);
    
    my $i;
    my $last_left;
    my $last_right;
    my $ldiff;
    my $rdiff;
    my $start;
    my $stop;
    if($arm == 1) {
	$start = $ma[0];
	$stop = $mir_end - 2;
    } elsif ($arm == 2) {
	$start = $sa[0];
	$stop = $star_end - 2;
    }
    for ($i = $start; $i <= $stop; ++$i) {
	if(exists($lr{$i})) {
	    if($last_left) {
		$ldiff = $i - $last_left;
		$rdiff = $last_right - $lr{$i};
		if (($ldiff == 1) and ($rdiff > 1)) {
		    # bulge
		    ++$bul_n;
		    $bul_nts += $rdiff - 1;
		} elsif (($ldiff > 1) and ($rdiff == 1)) {
		    # the other bulge
		    ++$bul_n;
		    $bul_nts += $ldiff - 1;
		} elsif (($ldiff > $rdiff) or ($ldiff < $rdiff)) {
		    # ail
		    ++$ail_n;
		    $ail_nts += abs ($ldiff - $rdiff);
		}
	    }
	    $last_left = $i;
	    $last_right = $lr{$i};
	}
    }
    # simplification .. report the number of assym nts
    my $out = $bul_nts + $ail_nts;
    return $out;
}
		
		
    

sub get_star {
    my($mir,$struc_results,$arm) = @_;
    # Parse mir
    my @ma = split ("_",$mir);  ## [0] is left-most, [1] is length
    # Parse $struc_results
    my @st = split ("\t", $struc_results);  ## [0] is brax
    my $star_5p;
    my $star_3p;
    # Different methods depending upon the arm of the mir
    if($arm == 1) {
	# mir is 5p arm, miR* is on 3p arm
	# get left-right lookup hash
	my %left_right = get_lr($st[0]);
	$star_5p = get_star_5p_1(\%left_right,\$mir);
	$star_3p = get_star_3p_1(\%left_right,\$mir);
    } elsif($arm == 2) {
	## mir is 3p arm, miR* is on 5p arm
	my %right_left = get_rl($st[0]);
	$star_5p = get_star_5p_2(\%right_left,\$mir);
	$star_3p = get_star_3p_2(\%right_left,\$mir);
    } else {
	return 0;
    }
    if(($star_5p) and ($star_3p)) {
	my $len = $star_3p - $star_5p + 1;
	my $out = "$star_5p" . "_" . "$len";
	return $out;
    } else {
	return 0;
    }
}

sub get_star_3p_2 {
    my($rl_hash,$mir) = @_; ## passed by reference. hash and scalar
    # parse mir
    my @mf = split ("_", $$mir);
    my $mir_end = $mf[0] + $mf[1] - 1;
    # Find the 3p end of the miR* for a miR on the 3p arm. This is across from the 5p end of the mir and then add 2
    my $i = $mf[0];
    until(exists($$rl_hash{$i})) {
	++$i;
	# sanity check / prevent infinite loop
	if($i >= $mir_end) {
	    return 0;
	}
    }
    my $j = $$rl_hash{$i};
    my $diff = $i - $mf[0] + 2; ## Add two for the 3' overhang
    my $star_3 = $j + $diff;
    return $star_3;
}
    
sub get_star_5p_2 {
    my($rl_hash,$mir) = @_; ## passed by reference. hash and scalar
    # parse mir
    my @mf = split ("_", $$mir);
    my $mir_end = $mf[0] + $mf[1] - 1;
    # Find the 5p end of the miR* for a miR on the 3p arm. This is across the 3p end of the miR - 2
    my $mir_end_less2 = $mir_end - 2;
    my $i = $mir_end_less2;
    until(exists($$rl_hash{$i})) {
	--$i;
	# sanity check / prevent infinite loop
	if($i <= $mf[0]) {
	    return 0;
	}
    }
    my $j = $$rl_hash{$i};
    my $diff = $mir_end_less2 - $i;
    my $star_5 = $j - $diff;
    return $star_5;
}
    
sub get_rl {
    my($brax) = @_;
    my %lr = get_lr($brax);
    my %rl = ();
    my $left;
    my $right;
    while(($left,$right) = each %lr) {
	$rl{$right} = $left;
    }
    return %rl;
}

sub get_star_3p_1 {
    my($lr_hash,$mir) = @_;  ## passed by reference. hash and scalar
    # Parse mir
    my @mf = split ("_", $$mir);
    my $mir_end = $mf[0] + $mf[1] - 1;
    # find the 3p of the miR* for a miR on the 5p arm.  This is across of the 5p of mir and then add 2
    my $i = $mf[0];
    until (exists($$lr_hash{$i})) {
	++$i;
	# sanity check / prevent infinite loop
	if($i >= $mir_end) {
	    return 0;
	}
    }
    my $j = $$lr_hash{$i};
    my $diff = $i - $mf[0] + 2; ## add two to account for two nt overhang
    my $star_3 = $j + $diff;
    return $star_3;
}

sub get_star_5p_1 {
    my($lr_hash,$mir) = @_;  ## passed by reference. hash and scalar
    # Parse mir
    my @mf = split ("_", $$mir);
    my $mir_end = $mf[0] + $mf[1] - 1;
    # find the 5p of the miR* for a miR on the 5p arm.  This is across of the 3p of mir - 2
    my $mir_end_less2 = $mir_end - 2;
    my $i = $mir_end_less2;
    until (exists($$lr_hash{$i})) {
	--$i;
	# sanity check / prevent infinite loop
	if($i <= $mf[0]) {
	    return 0;
	}
    }
    my $j = $$lr_hash{$i};
    my $diff = $mir_end_less2 - $i;
    my $star_5 = $j - $diff;
    return $star_5;
}

sub get_lr {
    my($brax) = @_;
    my %hash = ();
    my @char = split ('',$brax);
    my @lefts = ();
    my $i = 0;
    my $left;
    foreach my $ch (@char) {
	++$i;
	if($ch eq "\(") {
	    push(@lefts,$i);
	} elsif ($ch eq "\)") {
	    $left = pop @lefts;
	    $hash{$left} = $i;
	}
    }
    return %hash;
}

sub count_duplex_unpairs {
    my($brac) = @_;
    my $chopped = substr($brac,0,((length $brac) - 2));
    my $unp = 0;
    while ($chopped =~ /\./g) {
	++$unp;
    }
    return $unp;
}
    
    
sub score_brac_pairing {
    my($brac) = @_;
    my $score = 0;
    if($brac =~ /^[\.\(]+$/) {
	$score = 1; ## 5p arm .. all pairs are (
    } elsif ($brac =~ /^[\.\)]+$/) {
	$score = 2; ## 3p arm .. all pairs and )
    }
    return $score;
}
    

sub get_brax_subset {
    my($query,$struc_results) = @_;
    # Parse out query and struc_results
    my @qf = split ("_",$query);
    my @sr = split ("\t", $struc_results);
    my $offset = $qf[0] - 1; ## adjust to zero-based
    my $getlen = $qf[1];
    my $brax_subset = substr($sr[0],$offset,$getlen);
    return $brax_subset;
}

sub get_mod_seq {
    my($query,$mod_query,$seq,$strand) = @_;
    my $orig_start;
    my $orig_stop;
    if($query =~ /^\S+:(\d+)-(\d+)$/) {
	$orig_start = $1;
	$orig_stop = $2;
    } else {
	die "Abort: Parse error in sub-routine get_mod_seq\n";
    }
    my $mod_start;
    my $mod_stop;
    if($mod_query =~ /^\S+:(\d+)-(\d+)$/) {
	$mod_start = $1;
	$mod_stop = $2;
    } else {
	die "Abort: Parse error 2 in sub-routine get_mod_seq\n";
    }
    
    my $offset;
    if($strand eq "+") {
	$offset = $mod_start - $orig_start;
    } elsif ($strand eq "-") {
	$offset = $orig_stop - $mod_stop;
    } else {
	die "Fatal in sub-routine get_mod_seq failed to parse strand $strand\n";
    }
    
    my $getlen = $mod_stop - $mod_start + 1;
	    
    my $trimmed = substr($seq,$offset,$getlen);
    return $trimmed;
}

sub get_most_abun {
    my(%reads) = @_;
    my $max_freq = 0;
    my $max_entry;
    my $entry;
    my $freq;
    ## Note in case of ties, decision of which one to keep is arbitrary, based on the hash order
    while(($entry,$freq) = each %reads) {
	if($freq > $max_freq) {
	    $max_freq = $freq;
	    $max_entry = $entry;
	}
    }
    return $max_entry;
}

sub check_mature_match {
    my($mature,$seq) = @_;
    my @mature_match;  
    my $mat_start;
    my $mat_key;
    my $mat_length = length $mature;
    while($seq =~ /$mature/g) {
	$mat_start = (pos $seq) - (length $mature) + 1;
	$mat_key = "$mat_start" . "_" . "$mat_length";
	push(@mature_match,$mat_key)
    }
    return @mature_match;
}

sub get_read_hash {
    my($sam,$mod_query,$strand) = @_; ## Passed by reference
    # test
    #print STDERR "mod_query is $mod_query\n";
    
    # Parse mod_query coordinates
    my $pos_offset;
    my $neg_offset;
    if($$mod_query =~ /^\S+:(\d+)-(\d+)$/) {
	$pos_offset = $1;
	$neg_offset = $2;
    } else {
	die "Abort. Parse failure of mod_query $$mod_query in sub-routine get_read_hash\n";
    }
    my %hash = ();
    my @fields = ();
    my $read_len;
    my $mod_pos;
    my $key;
    my $read_end;
    foreach my $sam_line (@$sam) {
	chomp $sam_line;
	
	# test
	#print STDERR "$sam_line\n";
	
	@fields = split ("\t", $sam_line);
	$read_len = length $fields[9];
	
	# test
	#print STDERR "read_len: $read_len\n";
	
	if($$strand eq "+") {
	    $mod_pos = $fields[3] - $pos_offset + 1;
	    # test
	    #print STDERR "mod_pos of $mod_pos from fields3 $fields[3] - pos_offset $pos_offset + 1\n";
	} elsif ($$strand eq "-") {
	    $read_end = $fields[3] + $read_len - 1;
	    # test
	    #print STDERR "read_end of $read_end from fields3 $fields[3] + read_len $read_len - 1\n";
	    $mod_pos = $neg_offset - $read_end + 1;
	    # test
	    #print STDERR "mod_pos of $mod_pos from neg_offset of $neg_offset - read_end of $read_end + 1\n";
	} else {
	    die "Abort: Failed to parse \$\$strand in sub-routine get_read_hash\n";
	}
	$key = "$mod_pos" . "_" . "$read_len";
	# test
	#print STDERR "key of $key entered from mod_pos $mod_pos and read_len $read_len\n";
	
	++$hash{$key};
    }
    return %hash;
}
	

sub get_mod_query {
    my($struc_results,$query,$strand) = @_;
    
    # Parse out struc_results
    my @struc = split ("\t", $struc_results);
    my $loc_start = $struc[2];
    my $brax_len = length $struc[0];
    
    # Parse out original query
    my $chr;
    my $old_start;
    my $old_stop;
    if($query =~ /^(\S+):(\d+)-(\d+)$/) {
	$chr = $1;
	$old_start = $2;
	$old_stop = $3;
    } else {
	die "Abort:query parse error in sub-routine get_mod_query\n";
    }
    
    my $new_start;
    my $new_stop;
    my $mod_query;
    
    if($strand eq "+") {
	$new_start = $old_start + $loc_start - 1;
	$new_stop = $new_start + $brax_len - 1;
    } elsif ($strand eq "-") {
	$new_stop = $old_stop - $loc_start + 1;
	$new_start = $new_stop - $brax_len + 1;
    } else {
	die "Fatal in sub-routine get_mod_query .. strand of $strand was not recognized\n";
    }
    
    $mod_query = "$chr" . ":" . "$new_start" . "-" . "$new_stop";
	
    return $mod_query;
}

sub get_sam {
    my($bamfile,$query,$strand) = @_;
    # TEST
    #print STDERR "get_sam call received as $bamfile $query $strand for bamfile query strand\n";
    
    
    if($strand eq "+") {
	(open(SAM,"samtools view -F 0x10 $bamfile $query |")) || die "Abort: failed to open bam in sub-routine get_sam\n";
    } elsif ($strand eq "-") {
	(open(SAM,"samtools view -f 0x10 $bamfile $query |")) || die "Abort: failed to open bam in sub-routine get_sam\n";
    } else {
	return 0;
    }
    my @sam = ();
    my @fields = ();
    
    # Parse interval
    my $start;
    my $stop;
    if($query =~ /^(\S+):(\d+)-(\d+)$/) {
	$start = $2;
	$stop = $3;
    } else {
	return 0;
    }
    my $right_most;
    my $key;
    while (<SAM>) {
	chomp;
	@fields = split ("\t", $_);
	# no unmapped, just in case
	if($fields[1] & 4) {
	    next;
	}
	# left-most must be >= start and <= stop
	unless(($fields[3] >= $start) and ($fields[3] <= $stop)) {
	    next;
	}
	# right-most the same
	$right_most = $fields[3] + (length $fields[9]) - 1;
	unless(($right_most >= $start) and ($right_most <= $stop)) {
	    next;
	}
	# keeper
	push(@sam,$_);
    }
    close SAM;
    return @sam;
}

sub get_struc {
    my($seq) = @_;
    (open(FOLD, "echo $seq | RNALfold -L 1100 |")) || die "Abort: Failed to open RNALfold job in sub-routine get_struc.\n";
    my $best_dg = 0;
    my $best_brax;
    my $best_loc_st;
    my @fields = ();
    my $brax;
    my $start;
    my $dg;
    while (<FOLD>) {
	chomp;
	# reset each loop
	$brax = '';
	$start = '';
	$dg = '';
	if($_ =~ /^[^\.\(\)]/) {
	    ## this is a line that does not have a structure .. most likely the last line of output which just has the input sequence .. ignore it
	    next;
	}
	if($_ =~ /^\S+/) {
	    $brax = $&;
	}
	if($_ =~ /(\d+)\s*$/) {
	    $start = $1;
	}
	if($_ =~ /\(.*(-\d+\.\d+).*\)/) {
	    $dg = $1;
	}
	if(($brax) and ($start) and ($dg)) {
	    if($dg < $best_dg) {
		$best_dg = $dg;
		$best_brax = $brax;
		$best_loc_st = $start;
	    }
	}
    }
    close FOLD;
    my $out;
    if($best_brax) {
	$out = "$best_brax\t$best_dg\t$best_loc_st";
	return $out;
    } else {
	return 0;
    }
}
    

sub get_sense_seq {
    my($genomefile,$query) = @_;
    (open(FASTA, "samtools faidx $genomefile $query |")) || die "Abort: Failed to get query sequence in sub-routine get_sense_seq.\n";
    my $seq;
    while (<FASTA>) {
	chomp;
	unless ($_ =~ /^>/) {
	    $seq .= "$_";
	}
    }
    close FASTA;
    my $uc_seq = uc $seq;
    # Ts to Us
    $uc_seq =~ s/T/U/g;
    return $uc_seq;
}

sub check_coordinates {
    my($co,$fai) = @_;
    my $chr;
    my $start;
    my $stop;
    if($co =~ /^(\S+):(\d+)-(\d+)$/) {
	$chr = $1;
	$start = $2;
	$stop = $3;
    } else {
	print STDERR "Abort: Coordinates $co are not formatted properly. Should be Chr:start-stop\. See documentation\.\n";
	return 0;
    }
    # start has to be less than stop, duh
    unless($start < $stop) {
	print STDERR "Abort: Coordinates $co are invalid. Start must be less than stop.\n";
	return 0;
    }
    # start has to be 1 or more, duh
    unless($start >= 1) {
	print STDERR "Abort: Coordiantes $co are invalid. Start must be 1 or greater.\n";
	return 0;
    }
    # Chr must exist in the fai, and stop must still be on the chr
    (open(FAI, "$fai")) || die "Abort: Failed to open $fai in sub-routine check_coordinates.\n";
    my @f = ();
    my $chr_end;
    while (<FAI>) {
	chomp;
	@f = split ("\t", $_);
	if($f[0] eq $chr) {
	    $chr_end = $f[1];
	    last;
	}
    }
    close FAI;
    unless($chr_end) {
	print STDERR "Abort: Chromsome $chr from query $co is not found in the genome provided.\n";
	return 0;
    }
    unless($stop <= $chr_end) {
	print STDERR "Abort: Coordinates $co are invalid. Stop is longer than the end of the chromosome.\n";
	return 0;
    }
    # No queries longer than 1kb are allowed
    if(($stop - $start + 1) > 1000) {
	print STDERR "Abort: Coordinates $co are invalid. This program does not analyze queries larger than 1kb.\n";
	return 0;
    }
    return 1;
}

sub validate_bam {
    my($bam,$fai) = @_;
    # header checks
    my %h_seqs = ();
    (open(H, "samtools view -H $bam |")) || die "Abort: Failed to open bamfile for validation\n";
    my $h;
    my $so;
    my $rgname;
    my $sq;
    while (<H>) {
	if($_ =~ /^\@/) {
	    unless($h) {
		$h = 1;
	    }
	    if($_ =~ /^\@HD\t.*SO:(\S+)/) {
		if($1 eq "coordinate") {
		    $so = 1;
		} else {
		    $so = 0;
		}
	    }
	    if($_ =~ /^\@SQ\t.*SN:(\S+)/) {
		$h_seqs{$1} = 1;
		$sq = 1;
	    }
	}
    }
    close H;
    unless($h) {
	print STDERR "Abort: Bamfile has no header. See documentation.\n";
	return 0;
    }
    unless($so) {
	print STDERR "Abort: Sort order of bamfile is not indicated as \'coordinate\' in the header. See documentation.\n";
	return 0;
    }
    unless($sq) {
	print STDERR "Abort: no SQ lines found in the bamfile header. See documentation.\n";
	return 0;
    }
    
    # does it match the genome?
    my %fai_names = ();
    (open(FAI, "$fai")) || die "Abort: Failed to open faidx file during bamfile validation\n";
    my @fields = ();
    while (<FAI>) {
	@fields = split ("\t", $_);
	$fai_names{$fields[0]} = 1;
    }
    close FAI;
    my $h_seq;
    while(($h_seq) = each %h_seqs) {
	unless(exists($fai_names{$h_seq})) {
	    print STDERR "Abort: Chromosome $h_seq was specified in bamfile but not found in genome. See documentation.\n";
	    return 0;
	}
    }
    
    # Does it have X0 or XX tags?
    (open(SAM, "samtools view $bam |")) || die "Abort: Failed to open bamfile to check X0 or XX tags during validation.\n";
    my $check = <SAM>;
    close SAM;
    unless (($check =~ /\tXX:i:(\d+)/) or ($check =~ /\tX0:i:(\d+)/)) {
	print STDERR "Abort: alignment data appears to lack XX or X0 tags .. one of the two is required. See documentation.\n";
	return 0;
    }
    
    ## Is it indexed? If not, index it.
    my $bai = "$bam" . ".bai";
    unless (-r $bai) {
	print STDERR "Expected bamfile index $bai not found. Attempting to create using samtools index ..";
	system "samtools index $bam";
	if(-r $bai) {
	    print STDERR " Done\n";
	} else {
	    print STDERR " Failed. Aborting\n";
	    return 0;
	}
    }
    
    return 1;
}

__END__

=head1 LICENSE

EAPMA.pl

Copyright (C) 2014 Michael J. Axtell                                                             
                                                                                                 
This program is free software: you can redistribute it and/or modify                             
it under the terms of the GNU General Public License as published by                             
the Free Software Foundation, either version 3 of the License, or                                
(at your option) any later version.                                                              
                                                                                                 
This program is distributed in the hope that it will be useful,                                  
    but WITHOUT ANY WARRANTY; without even the implied warranty of                                   
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                                    
GNU General Public License for more details.                                                     
                                                                                                 
You should have received a copy of the GNU General Public License                                
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 SYNOPSIS

Empirical assessment of plant MIRNA annotations, based upon expression and predicted precursor secondary structure.

=head1 CITATION

As yet unpublished.

=head1 VERSION

dev3 : Unreleased development version. March 4, 2014

=head1 AUTHOR

Michael J. Axtell, Penn State University, mja18@psu.edu

=head1 DEPENDENCIES

    perl
    samtools
    RNALfold

Perl is required to be at /usr/bin/perl in order to compile EAPMA.

samtools <http://samtools.sourceforge.net/> needs to be installed in your PATH. EAPMA was developed using samtools 0.1.19.

RNALfold is from the ViennaRNA package. See <http://www.tbi.univie.ac.at/~ronny/RNA/vrna2.html>. RNALfold must in your PATH. EAPMA was developed using version 2.1.3

=head1 INSTALL

There is no real installation. Install samtools and RNALfold to your PATH. For convenience, EAPMA.pl can also be installed to your PATH.

=head1 USAGE

EAPMA.pl [options] [alignments.bam] [genome.fasta] [chr:start-stop]

Output goes to STDOUT

=head1 OPTIONS

--help : Print a help message and quit

--version: Print the version number and quit

--strand: Limit analysis to the indicated strand ("+" or "-"). If not specified, both strands will be analyzed

--mature: User-provided annotated or hypothesized mature miRNA sequence. Can be upper or lower case, U's or T's

=head1 ALIGNMENTS

Alignments must be provided in the BAM format, and must be sorted by coordinate. There are several other requirements as well (see below). It is strongly reccommended to use the following alignment protocol (using BWA):

1. Trim raw reads to remove 3' adapters, and, if desired, to retain high quality reads. This can be done with any number of publicly available tools, or simple scripts of your own devising. Retain reads in FASTQ or FASTA format. Do not 'condense' the reads by unique sequence .. each FASTA/Q entry should represent one read 'off the sequencer'.

2. To use bwa, first the genome FASTA file needs to be indexed:

bwa index genome.fasta

3. Align the trimmed FASTA/Q data using a bwa and samtools pipeline in conjunction with the indexed genome from step 2 , as shown below:

bwa aln -n 0 -o 0 -t 6 genome.fasta trimmed.fastq/a > aln.sai

The above call allows zero mismatches (-n 0), and 0 gaps (-o 0), and requests 6 processor cores (-t 6). Adjust -t as needed for you machine.

bwa samse -n 1 genome.fasta aln.sai trimmed.fastq/a | samtools view -S -b -u - | samtools sort - aln

The bwa samse call produces SAM-formatted alignments, reporting only 1 alignment per read (-n 1). The output is processed by samtools to sort it by chromsomal position and produce a BAM formatted alignment file, which will be named "aln.bam" in this example.

4. Index the bam file

samtools index aln.bam

=head2 BAM file format requirements

If you follow the reccommended alignment protocol above, your file will be properly formatted. But, just in case, the detailed format requirements for BAM alignments are as follows:

1. The file must end with the extension ".bam"

2. The file must have a header.

3. The BAM file must be sorted by 'coordinate', as indicated by the SO: tag in the header.

4. SQ lines must be present in the header, and they must all match names found in the genome.fasta file.

5. The alignment lines must have either X0:i: or XX:i: tags set. These are optional fields in the SAM format that indicate the number of equally valid alignment positions for the read. X0 tags are created by the bwa alignment method outlined above. XX tags are created by some versions of ShortStack.pl.

6. The BAM file should be indexed using samtools index. If it is not, EAPMA.pl will attempt to index it.

Finally, while not a formal requirement (only because there isn't an easy way to check), EAPMA assumes that each read is only present once in the alignment file. For multi-mapping reads, it is assumed that just one possible alignment was selected at random. The bwa method above accomplishes this.

=head1 PROCEDURES

After receiving a valid command, EAPMA does the following:

=head2 de novo and user-based analyses

All queries trigger a de novo analysis, which identifies the most abundant aligned RNA within the structure, and analyzes the structure under the hypothesis that this is the mature miRNA. In the case of a tie (more than one read with the max value), the mature miRNA is arbitrarily chosen. If the user specified a sequence with the option --mature, the user-based analysis is also performed, under the hypothesis that the user-specified sequence is the mature miRNA.

=head2 Structure Identification

The query sequence is analyzed with RNALfold. The predicted structure with the lowest predicted free energy is retained and used for further analysis. Only small RNA reads falling entirely within this structure are considered. Note that the identified structure is often smaller than the input query. If no structure at all can be recovered from the query, the locus is scored 0, and failed, and no further analysis is performed.

=head2 Small RNA alignment retrieval

All alignments within the identified structure are retrieved. This is strand-specific, and only those alignments whose starts and stops are both within the structure are retrieved. If no alignments are found, the locus is scored 0, and failed, and no further analysis is performed.

=head2 Analysis

Analysis of expression and structural features commences provided a structure is found and there are alignments present. Details in SCORING below.

=head1 SCORING

EAPMA uses a system based on both expression and structural criteria to score each query. The final score is equally divided between expression-based metrics and structure-based metrics, each of which account for 50% of the overall score. There are six expression-based metrics and five structure-based metrics, as detailed below. Each metric is given a score between 0 and 1 (with 0 being very poor and 1 being excellent). The six expression-based metrics are each weighted to 8.33% when calculating the overall score; the five expression-based metrics are each weighted to 10% each. The overall score thus also varies between 0 (poor) and 1 (excellent). In addition to the score, each locus is given a "PASS" or "FAIL" decision on whether the evidence supports annotation of the locus as a MIRNA.

=head2 Expression-based scoring

=head3 MULTI-MAPPED_CORRECTED_READ_TOTAL

This is the number of alignments after correcting for multi-mapping reads.

Scoring matrix:

Corrected_Reads Score

0-4             0

5-9             0.25

10-49           0.5

50-99           0.75

>=100           1

=head3 UNIQUELY_MAPPED_READS

This is the number of alignments for reads that were uniquely mapped to the locus. 

Scoring matrix:

Unique_Reads  Score

0             0

>=1           1

=head3 STAR_READS

This is the number of alignments for the miRNA-star sequence.

Scoring matrix:

Star_reads  Score

0           0  **causes decision of FAIL

1-5         0.5

>=6         1

=head3 miRNA_READS

This is the number of alignments for the mature miRNA sequence

Scoring matrix

miRNA_reads  Score

0-4          0 ** causes decision of FAIL

5-9          0.25

10-49        0.5

50-99        0.75

>=100        1

=head3 PRECISION

This is the number of miRNA + miRNA-star alignments divided by all alignments

Scoring matrix: Used directly.  ** <0.25 causes decision of FAIL

=head3 MIR_GTEQ_STAR

Whether or not the number of alignments for the hypothesized mature miRNA is greater than or equal to that of the hypothesized miRNA-star.

Scoring matrix

Answer  Score

Yes     1

No      0 ** causes decision of FAIL

=head2 Structure-based scoring

=head3 MIR_ARM

What arm of the stem is the hypothesized mature miRNA located on. For sequences that have predicted self-pairing, no arm can be determined (which causes a decision of FAIL).

Scoring matrix

Answer  Score

5p      1

3p      1

x       0 ** causes decision of FAIL

=head3 MIR_UNPAIRED

The number of nucleotides in the hypothesized mature miRNA that are unpaired.

Scoring matrix

n_unpaired  Score

0-3         1

4           0.5

5           0.25

>=6         0 ** causes decision of FAIL

=head3 STAR_COMPUTABLE

Whether or not the position of the hypothesized mature miRNA-star could be computed. Non-computable miRNA-stars indicate a highly aberrant stem-loop.

Scoring matrix

Answer  Score

Yes     1

No      0 ** causes decision of FAIL

=head3 N_BULGES_DUPLEX

The number of assymetric nucleotides in the hypothesized miRNA/miRNA-star duplex. This is calculated as the number of bulged nucleotides plus the number of 'excess' nucleotides in assymmetric internal loops. For instance, in an assymetric internal loop with 3 on one side and 2 on the other, 1 nt is in 'excess'.

Scoring matrix

n_assym Score

0-1     1

2       0.5

3       0.25

>=4     0 ** causes decision of FAIL

=head3 MAX_STEM_BUFFER

The maximum length of the stem flanking the hypothesized miRNA/miRNA-star duplex. This will either come from the loop-proximal or base-proximal side of the putative duplex. This is based on experimental and computational data indicating that plant MIRNA processing requires a spacing of about 15-17nts either from the base or the loop for the DCL enzyme to make the first 'cut'.

Scoring matrix

max_buffer  Score

>=15        1

13-14       0.25

<=12        0 

=head1 ALIGNMENTS

The text-based alignments show the sequence of the best structure and the predicted secondary structure in RNALfold dot-bracket notation. Each line under that represents a distinct read sequence. Note that the read sequences are pulled from the reference genome, not the reads themselves. In cases where read alignment allowed mismatches, this caveat becomes meaningful. 

All read lines have two values at the end. "l" represents the length of the read in nts, and "a" represents the number of alignments for that read.

"Special" read lines are those that correspond to the de-novo found candidate mature miRNA ("dn_miRNA"), the computed star of the de-novo found candidate mature miRNA ("dn_star"), the user-supplied candidate mature miRNA ("u_miRNA"), and the computed star of the user-defined candidate mature miRNA ("u_star"). Special lines use "*" characters for spacing if the read was expressed, and "x" characters if no reads were expressed. Also, in the cases where no reads were expressed, "a=0" will be present to indicate no alignments were present.

=head1 NOTES

=head2 Scoring vs. the Verdict

The scores of EAPMA are not directly linked to the "PASS" / "FAIL" decisions.  A locus can score very highly, but get a verdict of FAIL becuase it fell short in one key feature. Conversely, a locus could score lowly, but receive a verdict of PASS if it 'fails to fail' any of the key criteria.  For loci that PASS, the scores do however give some metric of confidence.

=head2 Limited judgements

Both the score and the verdict are conditional on both the hairpin structure and the expression level in the specific small RNA-seq library being examined. Therefore, it is important to note that a low score and/or a verdict of FAIL does not necessarily mean that a locus is not a MIRNA. For instance, it could be that the locus is lowly expressed in the library being considered. For more robust "blacklisting" and "whitelisting" of MIRNA annotations, loci should be queried in multiple libraries.

=head2 Adding flanking sequences

When using EAPMA to analyze existing MIRNA locus annotations from miRBase, it is a good idea to add some extra flanking sequence to the queries. Many miRBase hairpin entries are rather minimal, and don't include the full extent of the structured regions at the bases of the hairpins. Entering just these too-short queries could cause otherwise acceptable loci to fail because of insufficient buffer. Therefore I suggest padding all miRBase hairpin queries by 50nts on both sides to make sure the entire structured region is captured.

=cut