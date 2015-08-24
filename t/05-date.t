#!/usr/bin/perl
use strict;
use warnings;

use POSIX qw( strftime );
use Time::Local;

use Date::Calc qw(
    Date_to_Time
    Delta_Days
    Time_to_Date
    Today
);

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

use Test::More tests => 11527;


sub verify_yyyy_mm_dd_to_gmepoch {
    my ($days) = @_;
    my $now = timegm( 0, 0, 0, ( localtime )[ 3, 4, 5 ] );

    # for every day till the end of days
    for my $i ( 0 .. $days ) {
        my $epoch = $now - ( $i * 86400 ); # move back by that many days

        # and verify that we get the expected epoch
        my $date = strftime( "%Y-%m-%d", gmtime( $epoch ) );
        my $result = yyyy_mm_dd_to_gmepoch( $date );
        is( $result, $epoch, sprintf( "yyyy_mm_dd_to_gmepoch( '%s' ) == %d", $date, $epoch ) );
    }
}


sub verify_weekends {
    my ($days) = @_;

    my @day;
    # build a table with weekend days as 1 and other days as 0
    $days--;
    for my $i ( 0 .. $days ) {
        $day[ $i ] = ( $i % 7 == 0 ) || ( $i % 7 == 6 ) ? 1 : 0;
    }

    for my $start ( 0 .. 7 ) {
        # for each day of the week and twice on Sundays ...
        for my $end ( $start - 1 .. $days ) { # check that we get the expected result till the end of days

            # literally count the weekend days
            my $expected = 0;
            for my $i ( $start .. $end ) {
                $expected += $day[ $i ];
            }
            # and test it against what we get
            my $result = weekends( $start, $end - $start + 1 );
            is( $result, $expected, sprintf( "weekends( %d, %d ) == %d", $start, $end - $start + 1, $expected ) );
        }

        for my $end ( $start - 1 .. $days - $start ) { # check that we get the expected result till the end of days

            # literally count the weekend days
            my $expected = 0;
            for my $i ( $start .. $end ) {
                $expected += $day[ $i ];
            }
            # and test it against what we get
            my $result = weekends( $start, $end - $start + 1 );
            is( $result, $expected, sprintf( "weekends( %d, %d ) == %d", $start, $end - $start + 1, $expected ) );
        }

        for my $end ( -1 .. $days - $start ) { # check that we get the expected result till the end of days

            # literally count the weekend days
            my $expected = 0;
            for my $i ( $start .. $end ) {
                $expected += $day[ $i ];
            }
            # and test it against what we get
            my $result = weekends( $start, $end - $start + 1 );
            is( $result, $expected, sprintf( "weekends( %d, %d ) == %d", $start, $end - $start + 1, $expected ) );
        }

    }
}


sub verify_age {
    my ($days) = @_;
    reset_date_caches();
    my $now = timegm( 0, 0, 0, ( localtime )[ 3, 4, 5 ] );

    my $expected = 0;
    # for every day till the end of days
    for my $i ( 0 .. $days ) {
        my $epoch = $now - ( $i * 86400 ); # move back by that many days
        if ( $epoch < $now ) {
            $expected++;    # add a day to the expected age
        }

        # and verify that we get the expected age
        my $date = strftime( "%Y-%m-%d", gmtime( $epoch ) );
        my $result = days_age( $date );
        is( $result, $expected, sprintf( "days_age( '%s' ) == %d", $date, $expected ) );
        # Confirm with Date:Calc module as well
        $result = Delta_Days( ( Time_to_Date( $epoch ) )[ 0, 1, 2], ( Time_to_Date( $now ) )[ 0, 1, 2] );
        is( $result, $expected, sprintf( "Delta_Days( '%d-%d-%d', '%d-%d-%d' ) == %d", ( Time_to_Date( $epoch ) )[ 0, 1, 2], ( Time_to_Date( $now ) )[ 0, 1, 2], $expected ) );
    }
}


sub verify_age_dst {
    my @tests = (
        {
            start   => '2015-04-10',
            date    => '2015-02-01',
            age     => 68,
        },
        {
            start   => '2015-11-01',
            date    => '2015-09-01',
            age     => 61,
        },
    );
    for my $test ( @tests ) {
        reset_date_caches( yyyy_mm_dd_to_gmepoch( $test->{ start } ) );
        my $date = $test->{ date };
        my $expected = $test->{ age };
        my $result = days_age( $date );
        is( $result, $expected, sprintf( "days_age( '%s' ) == %d, (given today == %s)", $date, $expected, $test->{ start } ) );
    }
}


sub verify_weekdays_age {
    my ($days) = @_;
    my $now = timegm( 0, 0, 0, ( localtime )[ 3, 4, 5 ] );

    my $expected = 0;
    # for every day till the end of days
    for my $i ( 0 .. $days ) {
        my $epoch = $now - ( $i * 86400 ); # move back by that many days
        if ( $epoch < $now ) {
            my $day = ( gmtime( $epoch ) )[ 6 ];
            $expected++ if $day != 0 && $day != 6; # add a day to the expected age if it is not a weekend
        }

        # and verify that we get the expected age
        my $date = strftime( "%Y-%m-%d", gmtime( $epoch ) );
        my $result = weekdays_age( $date );
        is( $result, $expected, sprintf( "weekdays_age( '%s' ) == %d", $date, $expected ) );
    }
}


sub verify_special_days {
    my $expected = 12;
    my $result = scalar @{ load_special_days( 'holidays.txt' ) };
    is( $result, $expected, sprintf( "scalar load_special_days( 'holidays.txt' ) == %d", $expected ) );

    $expected = 8;
    $result = scalar @{ special_days( yyyy_mm_dd_to_gmepoch( '2015-01-01' ), yyyy_mm_dd_to_gmepoch( '2015-12-31' ) ) };
    is( $result, $expected, sprintf( "scalar special_days( yyyy_mm_dd_to_gmepoch( '2015-01-01' ), yyyy_mm_dd_to_gmepoch( '2015-12-31' ) ) == %d", $expected ) );
    $result = scalar @{ special_days( yyyy_mm_dd_to_gmepoch( '2015-12-31' ), yyyy_mm_dd_to_gmepoch( '2015-01-01' ) ) };
    is( $result, $expected, sprintf( "scalar special_days( yyyy_mm_dd_to_gmepoch( '2015-12-31' ), yyyy_mm_dd_to_gmepoch( '2015-01-01' ) ) == %d", $expected ) );

    $expected = 4;
    $result = scalar @{ special_days( yyyy_mm_dd_to_gmepoch( '2016-01-01' ), yyyy_mm_dd_to_gmepoch( '2016-12-31' ) ) };
    is( $result, $expected, sprintf( "scalar special_days( yyyy_mm_dd_to_gmepoch( '2016-01-01' ), yyyy_mm_dd_to_gmepoch( '2016-12-31' ) ) == %d", $expected ) );

    $expected = 3;
    $result = scalar @{ special_days( yyyy_mm_dd_to_gmepoch( '2015-04-01' ), yyyy_mm_dd_to_gmepoch( '2015-04-30' ) ) };
    is( $result, $expected, sprintf( "scalar special_days( yyyy_mm_dd_to_gmepoch( '2015-04-01' ), yyyy_mm_dd_to_gmepoch( '2015-04-30' ) ) == %d", $expected ) );

    $expected = 1;
    $result = scalar @{ special_days( yyyy_mm_dd_to_gmepoch( '2015-04-03' ), yyyy_mm_dd_to_gmepoch( '2015-04-03' ) ) };
    is( $result, $expected, sprintf( "scalar special_days( yyyy_mm_dd_to_gmepoch( '2015-04-03' ), yyyy_mm_dd_to_gmepoch( '2015-04-03' ) ) == %d", $expected ) );

    $expected = 0;
    $result = scalar @{ special_days( yyyy_mm_dd_to_gmepoch( '2015-11-01' ), yyyy_mm_dd_to_gmepoch( '2015-12-03' ) ) };
    is( $result, $expected, sprintf( "scalar special_days( yyyy_mm_dd_to_gmepoch( '2015-11-01' ), yyyy_mm_dd_to_gmepoch( '2015-12-03' ) ) == %d", $expected ) );
}


sub verify_special_age {
    my ($days) = @_;

    my $now = timegm( 0, 0, 0, ( localtime )[ 3, 4, 5 ] );

    my $result = scalar @{ load_special_days( 'holidays.txt' ) };
    is( $result, 12, sprintf( "scalar load_special_days( 'holidays.txt' ) == %d", 12 ) );
    my %special_day_epochs = map { $_ => 1 } @{ special_days( $now - ( $days * 86400 ), $now ) };

    my $expected = 0;
    # for every day till the end of days
    for my $i ( 0 .. $days ) {
        my $epoch = $now - ( $i * 86400 ); # move back by that many days
        if ( $epoch < $now ) {
            my $day = ( gmtime( $epoch ) )[ 6 ];
            $expected++ if $day != 0 && $day != 6 && ! exists $special_day_epochs{ $epoch }; # add a day to the expected age if it is not a weekend or a holiday
        }

        # and verify that we get the expected age
        my $date = strftime( "%Y-%m-%d", gmtime( $epoch ) );
        $result = special_age( $date );
        is( $result, $expected, sprintf( "special_age( '%s' ) == %d", $date, $expected ) );
    }
}


verify_yyyy_mm_dd_to_gmepoch( 400 );
verify_weekends( 400 );
verify_age_dst();
verify_age( 400 );
verify_weekdays_age( 400 );
verify_special_days();
verify_special_age( 400 );


__END__

=head1 DESCRIPTION

Tests for Git::Code::Review::Utilities::Date

=head1 AUTHOR

Samit Badle

=cut
