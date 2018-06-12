use warnings;
use strict;

use RT::Extension::ElapsedBusinessHours;

our $VERSION = '0.1';

use Set::Object;

our $start_time = '08:30';
our $end_time   = '17:30';
our $not_business_days = Set::Object->new(6, 7); # 6 = Saturday, 7 = Sunday, see DateTime
our $country  = 'NZ';
our $region = 'Wellington';
our $excluded_states = Set::Object->new('stalled', 'blocked', 'resolved', 'rejected', 'deleted');

use Date::Holidays;
our $dh = Date::Holidays->new(
    countrycode => $country,
);

sub calc {
    my $class = shift;
    my %args = ( Ticket => undef, CurrentUser => undef, DurationAsString => 0, Show => 4, Short => 1, @_);

    my $elapsed_business_time = 0;
    my $last_state_change = $args{Ticket}->CreatedObj;
    my $clock_running = 1;

    my $transactions = $args{Ticket}->Transactions;
    while (my $trans = $transactions->Next) {
        RT->Logger->error("Ticket: ", $trans->ObjectId, ", Transaction: ", $trans->id, ", Type: ". $trans->Type);
        if ($trans->Type eq 'Status') {
            RT->Logger->error("Field: ", $trans->Field, ", Old: ", $trans->OldValue, ", New: ". $trans->NewValue, ", Created: ", $trans->CreatedObj->W3CDTF);
            if ($clock_running && $excluded_states->includes($trans->NewValue)) {
                RT->Logger->error("  excluded state, stop the clock!");
                $clock_running = 0;

                $elapsed_business_time += calc_elapsed($last_state_change, $trans->CreatedObj)

            } elsif (! $clock_running && ! $excluded_states->includes($trans->NewValue)) {
                RT->Logger->error("  included state, start the clock!");
                $clock_running = 1;
                $last_state_change = $trans->CreatedObj;
            }
        }
    };

    if ($clock_running) {
        RT->Logger->error("  clock still running, but no more transactions, add to now");
        my $now = RT::Date->new($args{CurrentUser}->UserObj);
        $now->SetToNow;
RT->Logger->error("  last_state_change: ", $last_state_change->W3CDTF, ", now: ", $now->W3CDTF);
        $elapsed_business_time += calc_elapsed($last_state_change, $now)
    }

    if ($args{DurationAsString}) {
        return $last_state_change->DurationAsString(
            $elapsed_business_time,
            Show => $args{Show},
            Short => $args{Short},
        );
    } else {
        return sprintf("%d:%02d", int($elapsed_business_time / 60), $elapsed_business_time % 60);
    }
}

sub calc_elapsed {
    my ($last_state_change, $current_date) = @_;
    my $elapsed_business_time = 0;

    # Track the timezone so we can propogate it later.
    my $timezone = $current_date->Timezone('user');

    # Work out the difference between $last_state_change_time and $trans->Created counting only business hours and skipping weekends and holidays. How hard can that be?!;
    my $dt_current_date = $current_date->DateTimeObj;
    $dt_current_date->set_time_zone($timezone);

    my $dt_working = $last_state_change->DateTimeObj;
    $dt_working->set_time_zone($timezone);

    $last_state_change = $current_date;

    RT->Logger->debug("trying to add time from ", $dt_working->strftime("%FT%T %Z"), " until ", $dt_current_date->strftime("%FT%T %Z"));

    while ($dt_working < $dt_current_date) {

        if ($not_business_days->includes($dt_working->day_of_week)) {
            RT->Logger->debug("Not business day (", $dt_working->ymd, "), skip");
            next;
        }

        my ($year, $month, $day) = split(/-/, $dt_working->ymd);
        if ($dh->is_holiday(year => $year, month => $month, day => $day, region => $region)) {
            RT->Logger->debug("holiday (", $dt_working->ymd, "), skip");
            next;
        }

# If time is before 9am, continue
# If time is after 5pm, set end time to 5pm.
# If time is before 5pm, set end time to time
# elapsed_business_seconds += end time - 9am
# continue

        my $day_start;
        if (defined $start_time && $start_time =~ /^(\d+)(?::(\d+)(?::(\d+))?)?$/) {
            my $bus_start_time = $dt_working->clone;
            RT->Logger->debug("bus_start_time TZ: " . $bus_start_time->time_zone_short_name());
         
            $bus_start_time->set_hour($1);
            $bus_start_time->set_minute($2 || 0);
            $bus_start_time->set_second($3 || 0);

            if ($dt_current_date <= $bus_start_time) {
                RT->Logger->debug("end of work is before business day begins, skip");
                next;
            } elsif ($dt_working > $bus_start_time) {
                RT->Logger->debug("start of work is after business day begins");
                $day_start = $dt_working;
            } else {
                RT->Logger->debug("start of work is before business day begins");
                $day_start = $bus_start_time;
            }
        }

        RT->Logger->debug("going to add time for: (", $dt_working->ymd, ")");

        my $day_end;
        if (defined $end_time && $end_time =~ /^(\d+)(?::(\d+)(?::(\d+))?)?$/) {
            my $bus_end_time = $dt_working->clone;
            RT->Logger->debug("bus_end_time TZ: " . $bus_end_time->time_zone_short_name());
            $bus_end_time->set_hour($1);
            $bus_end_time->set_minute($2 || 0);
            $bus_end_time->set_second($3 || 0);

            if ($dt_current_date <= $bus_end_time) {
                RT->Logger->debug("end of work is before business day ends");
                $day_end = $dt_current_date;
            } else {
                RT->Logger->debug("end of work is after business day ends, or another day, use $end_time");
                $day_end = $bus_end_time;
            }
        }

        my $delta = $day_end - $day_start;
RT->Logger->error("  day_start: ", $day_start->datetime, ", day_end: ", $day_end->datetime, ", delta: ", $delta->deltas, ", running elapsed_business_time: $elapsed_business_time");

        # We'll ignore leap seconds.
        my ($minutes, $seconds) = $delta->in_units('minutes', 'seconds');
        $elapsed_business_time += ($minutes * 60) + $seconds;
    } continue {
        $dt_working->add( days => 1 );
        $dt_working->set( hour => 0, minute => 0, second => 0 );
    }

RT->Logger->error("  running elapsed_business_time: $elapsed_business_time");
    return $elapsed_business_time;
}

1;
