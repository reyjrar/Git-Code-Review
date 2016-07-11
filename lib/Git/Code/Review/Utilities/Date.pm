package Git::Code::Review::Utilities::Date;
# ABSTRACT: Date calculation and manipulations
use strict;
use warnings;

use Time::Local;

our $VERSION = 0.01;
use Exporter 'import';
our @EXPORT_OK = qw(
    days_age
    load_special_days
    reset_date_caches
    special_age
    special_days
    weekends
    weekdays_age
    yyyy_mm_dd_to_gmepoch
);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

# Converts a date in yyyy-mm-dd format to an epoch
sub yyyy_mm_dd_to_gmepoch {
    my ($date) = @_;

    # Get Y, M, D parts.
    my @parts = reverse split '-', $date;
    # Decrement Month
    $parts[ 1 ]--;
    return timegm( 0, 0, 0, @parts );
}

my $TODAY;
my %_Ages = ();
sub days_age {
    my ($date) = @_;
    return $_Ages{ $date } if exists $_Ages{ $date };

    my $epoch = yyyy_mm_dd_to_gmepoch( $date );
    my $diff  = $TODAY - $epoch;
    my $days_old = int( $diff / 86400 );
#    printf "now: %d, epoch: %d, diff: %d, days: %f\n", $TODAY, $epoch, $diff, ($diff / 86400);
    return $_Ages{ $date } = $days_old;
}

# $start_day: 0 = Sun .. 6 = Sat ( day of the week as returned by localtime ), it will also work for 7 = Sun
sub weekends {
    my ($start_day, $days) = @_;
    return 0 if $days <= 0; # no days == no weekends
    $start_day %= 7;
    return 1 + weekends( 1, $days - 1 ) if $start_day == 0; # shift Sunday to Monday
    my $weekends = int( $days / 7 ) * 2;    # we have 2 weekends every 7 days
    # calc if left over days cross Saturday. ( 6 - $start_day ) is days to Saturday
    my $leftover = ( $days % 7 ) - ( 6 - $start_day );
    # $leftover == 1 => crosses Saturday, $leftover == 2 => crosses Saturday and Sunday
    return $weekends + ( $leftover <= 0 ? 0 : $leftover <= 1 ? 1 : 2 );
}

my %_Weekday_Ages = ();
sub weekdays_age {
    my ($date) = @_;
    return $_Weekday_Ages{ $date } if exists $_Weekday_Ages{ $date };

    my $epoch = yyyy_mm_dd_to_gmepoch( $date );
    my $age = days_age( $date );
    return $_Weekday_Ages{ $date } = $age - weekends( ( gmtime( $epoch ) )[ 6 ], $age );
}

my @_Special_Days = ();
sub load_special_days {
    my (@files) = @_;
    if ( scalar @files ) {
        my %days = map { $_ => 1 } @_Special_Days;
        for my $file ( @files ) {
            open( my $fh, '<', $file);
            while ( <$fh> ) {
                s/#.*$//;  # remove comments
                for my $date ( split /,/ ) {
                    $date =~ s/^\s+//g;
                    $date =~ s/\s+$//g;
                    next unless $date;
                    if ( $date =~ m/\d{4}-\d{2}-\d{2}/ ) {
                        my $epoch = yyyy_mm_dd_to_gmepoch( $date );
                        my $dow = ( gmtime( $epoch ) )[ 6 ];
                        if ( $dow == 6 || $dow == 0 ) {
#                            print "Ignoring $date as it falls on a Saturday or a Sunday\n";
                        } else {
                            $days{ $epoch }++;
#                            print "Added $date to special days\n";
                        }
                    } else {
                        warn "Discarding invalid date: $date\n";
                    }
                }
            }
            close $fh;
        }
        # store sorted epochs
        @_Special_Days = sort { $a <=> $b } keys %days;
    }
    return [ @_Special_Days ];  # return a copy so that the original cannot be modified
}

sub special_days {
    my ($epoch1, $epoch2) = @_;

    if ( $epoch1 > $epoch2 ) {
         ( $epoch1, $epoch2 ) = ( $epoch2, $epoch1 );
    }
    # TODO if we start having a large number of special days, we should optimise this search
    my @dates = grep { $_ >= $epoch1 && $_ <= $epoch2 } @_Special_Days;
    return \@dates;
}

# age excluding weekend days and special days, call load_special_days() if you want to setup any special days
my %_Special_Ages = ();
sub special_age {
    my ($date) = @_;
    return $_Special_Ages{ $date } if exists $_Special_Ages{ $date };

    my $epoch = yyyy_mm_dd_to_gmepoch( $date );
    return $_Special_Ages{ $date } = weekdays_age( $date ) - scalar @{ special_days( $epoch, $TODAY ) };
}

sub reset_date_caches {
    my ($today) = @_;
    $TODAY = $today || timegm( 0, 0, 0, ( localtime )[ 3, 4, 5 ] );
    %_Ages = ();
    %_Weekday_Ages = ();
    %_Special_Ages = ();
    @_Special_Days = ();
}

reset_date_caches();

1;

__END__

=head1 NAME

Git::Code::Review::Utilities::Date - Age handling for Git::Code::Review

=head1 SYNOPSIS

use Git::Code::Review::Utilities::Date qw(
    days_age
    load_special_days
    reset_date_caches
    special_age
    special_days
    weekends
    weekdays_age
    yyyy_mm_dd_to_gmepoch
);

=head1 DESCRIPTION

Age, weekend, and special day calculation module optimised for to age calculations from a day in the past to today

=head1 FUNCTIONS

=head2 days_age

 my $age = days_age( '2015-07-12' );

Get the number of days between today and the specified day in YYYY-MM-DD format. You can set the date used for
today using reset_date_caches() function. If today is '2015-08-12', days_age( '2015-08-11' ) should return 1.

=head2 load_special_days

 my $special_days = load_special_days( 'national_holidays_nl.txt', 'non_working_days.txt', 'sick_days.txt' );
 my $special_days = load_special_days();

Loads special days from one or more text files containing special days in a YYYY-MM-DD format. The files can have
one or more dates per line. If more than one dates are on a line, they should be separated by commas. White spaces
can be added around the dates and will be ignored and so will any part of the line starting from a # character to
allow comments. See the holidays.txt in the tests for a sample file. Special days falling on a Saturday or a Sunday
are ignored.

Returns a copy of the currently loaded special days. Call without any arguments to get the complete current list of
special days. You can also use special_days() to get a list of special days between two dates.

=head2 reset_date_caches

 reset_date_caches();
 reset_date_caches( yyyy_mm_dd_to_gmepoch( '2015-08-01' ) );

Clear all the internal caches of ages and special days and reset the TODAY epoch used internally to the current day
or the one supplied. Useful when the day changes or during testing. Do remember to load the special days if you
want them again.

=head2 special_age

 my $age = special_age( '2015-08-01' );

Get the number of days between today and the specified day in YYYY-MM-DD format excluding the weekend days and
currently loaded special days. You can set the date used for today using reset_date_caches() function.

=head2 special_days

 my $special_days = special_days( yyyy_mm_dd_to_gmepoch( '2015-04-01' ), yyyy_mm_dd_to_gmepoch( '2015-04-30' ) );

Get a array_ref to the special days included in the given date range, both inclusive. The returned list contains
epochs as returned by yyyy_mm_dd_to_gmepoch() function.

=head2 weekends

 my $weekends = weekends( $start_day, $days );
 my $weekends = weekends( 1, 10 ); # 1 = Monday && 10 days

Returns the number of weekend days in a period of days starting on a given week day. The start_day can be 0 .. 6 for
Sunday .. Saturday or 1 .. 7 for Monday .. Sunday.

=head2 weekdays_age

 my $age = weekdays_age( '2015-08-01' );

Get the number of days between today and the specified date in YYYY-MM-DD format excluding the weekend days.
You can set the date used for today using reset_date_caches() function.

=head2 yyyy_mm_dd_to_gmepoch

 my $epoch = yyyy_mm_dd_to_gmepoch( '2015-08-01' );

Returns the midnight epoch for the date specified in the YYYY-MM-DD format in GMT timezone. There is no Daylight
Saving Time in GMT, which makes it easier for calculations.

=head1 AUTHOR

Samit Badle

=head1 COPYRIGHT

(c) 2015 All rights reserved.

=cut
