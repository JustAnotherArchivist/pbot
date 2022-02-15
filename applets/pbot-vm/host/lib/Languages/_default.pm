#!/usr/bin/perl

# SPDX-FileCopyrightText: 2021 Pragmatic Software <pragma78@gmail.com>
# SPDX-License-Identifier: MIT

use 5.020;

use warnings;
use strict;

use feature qw(switch unicode_strings signatures);
no warnings qw(experimental::smartmatch experimental::signatures);

package Languages::_default;

use Encode;
use JSON::XS;
use Getopt::Long qw(GetOptionsFromArray :config pass_through no_ignore_case no_auto_abbrev);
use Time::HiRes qw(gettimeofday);

use FindBin qw($RealBin);

use InteractiveEdit;
use Paste;
use SplitLine;

sub new {
    my ($class, %conf) = @_;
    my $self = bless {}, $class;

    %$self = %conf;

    $self->{debug}           //= 0;
    $self->{arguments}       //= '';
    $self->{default_options} //= '';
    $self->{max_history}     //= 10000;

    $self->initialize(%conf);

    # remove leading and trailing whitespace
    $self->{nick}    =~ s/^\s+|\s+$//g;
    $self->{channel} =~ s/^\s+|\s+$//g;
    $self->{lang}    =~ s/^\s+|\s+$//g;

    return $self;
}

sub initialize($self, %conf) {}

sub process_interactive_edit($self) {
    return interactive_edit($self);
}

sub process_standard_options($self) {
    my @opt_args = split_line($self->{code}, preserve_escapes => 1, keep_spaces => 0);

    my $getopt_error;
    local $SIG{__WARN__} = sub {
        $getopt_error = shift;
        chomp $getopt_error;
    };

    my ($info, $arguments, $paste);
    GetOptionsFromArray(\@opt_args,
        'info!' => \$info,
        'args|arguments=s' => \$arguments,
        'paste!' => \$paste);

    if ($info) {
        my $cmdline = $self->{cmdline};
        if (length $self->{default_options}) {
            $cmdline =~ s/\$options/$self->{default_options}/;
        } else {
            $cmdline =~ s/\$options\s+//;
        }
        $cmdline =~ s/\$sourcefile/$self->{sourcefile}/g;
        $cmdline =~ s/\$execfile/$self->{execfile}/g;
        my $name = exists $self->{name} ? $self->{name} : $self->{lang};
        print "$name cmdline: $cmdline\n";
        exit;
    }

    if (defined $arguments) {
        if (not $arguments =~ s/^"(.*)"$/$1/) {
            $arguments =~ s/^'(.*)'$/$1/;
        }
        $self->{arguments} = $arguments;
    }

    if ($paste) {
        $self->add_option("-paste");
    }

    $self->{code} = join ' ', @opt_args;

    if ($self->{code} =~ s/-stdin[ =]?(.*)$//) {
        $self->add_option("-stdin", $1);
    }
}

sub process_custom_options {}

sub process_cmdline_options($self) {
    my $code = $self->{code};

    $self->{cmdline_options} = "";

    while ($code =~ s/^\s*(-[^ ]+)\s*//) {
        $self->{cmdline_options} .= "$1 ";
        $self->add_option($1);
    }

    $self->{cmdline_options} =~ s/\s$//;

    $self->{code} = $code;
}

sub add_option($self, $option, $value = '') {
    $self->{options_order} //= [];
    $self->{options}->{$option} = $value;
    push @{$self->{options_order}}, $option;
}

sub pretty_format($self, $code) {
    return $code;
}

sub preprocess_code($self, %opts) {
    if ($self->{only_show}) {
        print "$self->{code}\n";
        exit;
    }

    unless($self->{got_run} and $self->{copy_code}) {
        open LOG, ">> $RealBin/../log.txt";
        print LOG localtime() . "\n";
        print LOG "$self->{nick} $self->{channel}: [" . $self->{arguments} . "] " . $self->{cmdline_options} . "$self->{code}\n";
        close LOG;
    }

    # replace \n outside of quotes with literal newline
    my $new_code = "";

    use constant {
        NORMAL        => 0,
        DOUBLE_QUOTED => 1,
        SINGLE_QUOTED => 2,
    };

    my $state = NORMAL;
    my $escaped = 0;

    my @chars = split //, $self->{code};
    foreach my $ch (@chars) {
        given ($ch) {
            when ('\\') {
                if ($escaped == 0) {
                    $escaped = 1;
                    next;
                }
            }

            if ($state == NORMAL) {
                when ($_ eq '"' and not $escaped) {
                    $state = DOUBLE_QUOTED;
                }

                when ($_ eq "'" and not $escaped) {
                    $state = SINGLE_QUOTED;
                }

                when ($_ eq 'n' and $escaped == 1) {
                    $ch = "\n";
                    $escaped = 0;
                }
            }

            if ($state == DOUBLE_QUOTED) {
                when ($_ eq '"' and not $escaped) {
                    $state = NORMAL;
                }
            }

            if ($state == SINGLE_QUOTED) {
                when ($_ eq "'" and not $escaped) {
                    $state = NORMAL;
                }
            }
        }

        $new_code .= '\\' and $escaped = 0 if $escaped;
        $new_code .= $ch;
    }

    if (!$opts{omit_prelude} && exists $self->{prelude}) {
        $self->{code} = "$self->{prelude}\n$self->{code}";
    }

    $self->{code} = $new_code;
}

sub execute {
    my ($self) = @_;

    my $input  = $self->{'vm-input'};
    my $output = $self->{'vm-output'};

    my $date = time;
    my $stdin = $self->{options}->{'-stdin'};

    if (not length $stdin) {
        $stdin = `fortune -u -s`;
        $stdin =~ s/[\n\r\t]/ /msg;
        $stdin =~ s/:/ - /g;
        $stdin =~ s/\s+/ /g;
        $stdin =~ s/^\s+//;
        $stdin =~ s/\s+$//;
    }

    $stdin =~ s/(?<!\\)\\n/\n/mg;
    $stdin =~ s/(?<!\\)\\r/\r/mg;
    $stdin =~ s/(?<!\\)\\t/\t/mg;
    $stdin =~ s/(?<!\\)\\b/\b/mg;
    $stdin =~ s/(?<!\\)\\x([a-f0-9]+)/chr hex $1/igme;
    $stdin =~ s/(?<!\\)\\([0-7]+)/chr oct $1/gme;

    my $pretty_code = $self->pretty_format($self->{code});

    my $cmdline = $self->{cmdline};

    $cmdline =~ s/\$sourcefile/$self->{sourcefile}/g;
    $cmdline =~ s/\$execfile/$self->{execfile}/g;

    my $options = length $self->{cmdline_options} ? $self->{cmdline_options} : $self->{default_options};

    if ((not exists $self->{options}->{'-paste'}) and (not defined $self->{got_run} or $self->{got_run} ne 'paste')) {
        if (exists $self->{options_nopaste}) {
            $options .= ' ' if length $options;
            $options .= $self->{options_nopaste};
        }
    } else {
        if (exists $self->{options_paste}) {
            $options .= ' ' if length $options;
            $options .= $self->{options_paste};
        }
    }

    if (length $options) {
        $cmdline =~ s/\$options/$options/;
    } else {
        $cmdline =~ s/\$options\s+//;
    }

    open LOG, ">> $RealBin/../log.txt";
    print LOG "---------------------executing---------------------------------------------------\n";
    print LOG localtime() . "\n";
    print LOG "$cmdline\n$stdin\n$pretty_code\n";

    my $compile_in = {
        lang       => $self->{lang},
        sourcefile => $self->{sourcefile},
        execfile   => $self->{execfile},
        cmdline    => $cmdline,
        input      => $stdin,
        date       => $date,
        arguments  => $self->{arguments},
        code       => $pretty_code
    };

    $compile_in->{'factoid'} = $self->{'factoid'} if length $self->{'factoid'};
    $compile_in->{'persist-key'} = $self->{'persist-key'} if length $self->{'persist-key'};

    my $compile_json = encode_json($compile_in);
    $compile_json .= encode('UTF-8', "\n:end:\n");

    my $length = length $compile_json;
    my $sent = 0;
    my $chunk_max = 4096;
    my $chunk_size = $length < $chunk_max ? $length : $chunk_max;
    my $chunks_sent = 0;

    #print LOG "Sending $length bytes [$compile_json] to vm_server\n";

    $chunk_size -= 1; # account for newline in syswrite

    while ($chunks_sent < $length) {
        my $chunk = substr $compile_json, $chunks_sent, $chunk_size;

        $chunks_sent += length $chunk;

        my $ret = syswrite($input, $chunk);

        if (not defined $ret) {
            print STDERR "Error sending: $!\n";
            print LOG "Error sending: $!\n";
            last;
        }

        if ($ret == 0) {
            print STDERR "Sent 0 bytes. Sleep 1 sec and try again\n";
            print LOG "Sent 0 bytes. Sleep 1 sec and try again\n";
            sleep 1;
            next;
        }

        $sent += $ret;
    }

    close LOG;

    my $result = "";
    my $got_result = 0;

    while (my $line = <$output>) {
        utf8::decode($line);
        $line =~ s/[\r\n]+$//;
        last if $line =~ /^result:end$/;

        if ($line =~ /^result:/) {
            $line =~ s/^result://;
            my $compile_out = decode_json($line);
            $result .= "$compile_out->{result}\n";
            $got_result = 1;
            next;
        }

        if ($got_result) {
            $result .= "$line\n";
        }
    }

    close $input;

    $self->{output} = $result;

    return $result;
}

sub postprocess_output($self) {
    unless($self->{got_run} and $self->{copy_code}) {
        open LOG, ">> $RealBin/../log.txt";
        print LOG "--------------------------post processing----------------------------------------------\n";
        print LOG localtime() . "\n";
        print LOG "$self->{output}\n";
        close LOG;
    }

    # backspace
    my $boutput = "";
    my $active_position = 0;
    $self->{output} =~ s/\n$//;
    while ($self->{output} =~ /(.)/gms) {
        my $c = $1;
        if ($c eq "\b") {
            if (--$active_position <= 0) {
                $active_position = 0;
            }
            next;
        }
        substr($boutput, $active_position++, 1) = $c;
    }
    $self->{output} = $boutput;

    my @beeps = qw/*BEEP* *BING* *DING* *DONG* *CLUNK* *BONG* *PING* *BOOP* *BLIP* *BOP* *WHIRR*/;

    $self->{output} =~ s/\007/$beeps[rand @beeps]/g;
}

sub show_output($self) {
    my $output = $self->{output};

    unless ($self->{got_run} and $self->{copy_code}) {
        open LOG, ">> $RealBin/../log.txt";
        print LOG "------------------------show output------------------------------------------------\n";
        print LOG localtime() . "\n";
        print LOG "$output\n";
        print LOG "========================================================================\n";
        close LOG;
    }

    if (exists $self->{options}->{'-paste'} or (defined $self->{got_run} and $self->{got_run} eq 'paste')) {
        my $cmdline = "command: $self->{cmdline}\n";

        $cmdline =~ s/\$sourcefile/$self->{sourcefile}/g;
        $cmdline =~ s/\$execfile/$self->{execfile}/g;

        my $options;
        if (length $self->{cmdline_options}) {
            $options = $self->{cmdline_options};
        } else {
            $options = $self->{default_options};
        }

        if (exists $self->{options_paste}) {
            $options .= ' ' if length $options;
            $options .= $self->{options_paste};
        }

        if (length $options) {
            $cmdline =~ s/\$options/$options/;
        } else {
            $cmdline =~ s/\$options\s+//;
        }

        if (length $self->{arguments}) {
            $cmdline .= "arguments: $self->{arguments}\n";
        }

        if ($self->{options}->{'-stdin'}) {
            $cmdline .= "stdin: $self->{options}->{'-stdin'}\n";
        }

        my $pretty_code = $self->pretty_format($self->{code});

        my $cmdline_opening_comment = $self->{cmdline_opening_comment} // "/************* CMDLINE *************\n";
        my $cmdline_closing_comment = $self->{cmdline_closing_comment} // "************** CMDLINE *************/\n";

        my $output_opening_comment = $self->{output_opening_comment} // "/************* OUTPUT *************\n";
        my $output_closing_comment = $self->{output_closing_comment} // "************** OUTPUT *************/\n";

        $pretty_code .= "\n\n";
        $pretty_code .= $cmdline_opening_comment;
        $pretty_code .= "$cmdline";
        $pretty_code .= $cmdline_closing_comment;

        $output =~ s/\s+$//;
        $pretty_code .= "\n";
        $pretty_code .= $output_opening_comment;
        $pretty_code .= "$output\n";
        $pretty_code .= $output_closing_comment;

        my $uri = $self->paste_0x0($pretty_code);
        print "$uri\n";
        exit 0;
    }

    if ($self->{channel} =~ m/^#/ and length $output > 22 and open LOG, "< $RealBin/../history/$self->{channel}-$self->{lang}.last-output") {
        my $last_output;
        my $time = <LOG>;

        if (gettimeofday - $time > 60 * 4) {
            close LOG;
        } else {
            while (my $line = <LOG>) {
                $last_output .= $line;
            }
            close LOG;

            if ((not $self->{factoid}) and defined $last_output and $last_output eq $output) {
                print "Same output.\n";
                exit 0;
            }
        }
    }

    print "$output\n";

    open LOG, "> $RealBin/../history/$self->{channel}-$self->{lang}.last-output" or die "Couldn't open $self->{channel}-$self->{lang}.last-output: $!";
    my $now = gettimeofday;
    print LOG "$now\n";
    print LOG "$output";
    close LOG;
}

1;
