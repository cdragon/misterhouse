# Category=MisterHouse

$v_reload_code = new  Voice_Cmd("{Reload,re load} code");
$v_reload_code-> set_info('Load new mh.ini, icon, and/or code changes');
if (state_now $v_reload_code) {
    read_code();
    $Run_Members{mh_control} = 2; # Reset, so the mh_temp.user_code decrement works
}

$v_read_tables = new Voice_Cmd 'Read table files';
read_table_files if said $v_read_tables;

$v_set_password = new  Voice_Cmd("Set the password");
if (said $v_set_password) {
    @ARGV = ();
    do "$Pgm_PathU/set_password";
}

$v_uptime = new  Voice_Cmd("What is your up time?", 0);
$v_uptime-> set_info('Check how long the comuter and MisterHouse have been running');

if (said $v_uptime) {
    my $uptime_pgm      = &time_diff($Time_Startup_time, time);
    my $uptime_computer = &time_diff($Time_Boot_time, (get_tickcount)/1000);
#   speak("I was started on $Time_Startup\n");
    speak("I was started $uptime_pgm ago. The computer was booted $uptime_computer ago.");
}

$v_reboot = new  Voice_Cmd("Reboot the computer");
$v_reboot-> set_info('Do this only if you really mean it!  Windows only');

if (said $v_reboot and $OS_win) {
#   if ($Info{OS_name} eq 'Win95') {
#        speak "Sorry, the reboot option does not work on Win95";
#   }
    if ($Info{OS_name} eq 'NT') {
        speak "The house computer will reboot in 1 minute.";
        Win32::InitiateSystemShutdown('HOUSE', 'Rebooting in 5 minutes', 60, 1, 1);
        &exit_pgm;
    }
    else {
        run 'rundll32.exe shell32.dll,SHExitWindowsEx 6 ';
        &exit_pgm;
    }
}

#http://support.microsoft.com/support/kb/articles/q234/2/16.asp
#  rundll32.exe shell32.dll,SHExitWindowsEx n
#where n is one, or a combination of, the following numbers:
#0 - LOGOFF
#1 - SHUTDOWN
#2 - REBOOT
#4 - FORCE
#8 - POWEROFF
#The above options can be combined into one value to achieve different results. 
#For example, to restart Windows forcefully, without querying any running programs, use the following command line: 
#rundll32.exe shell32.dll,SHExitWindowsEx 6 

#$v_reboot_abort = new  Voice_Cmd("Abort the reboot");
#if (said $v_reboot_abort and $OS_win) {
#  Win32::AbortSystemShutdown('HOUSE');
#  speak("OK, the reboot has been aborted.");
#}

$v_debug = new  Voice_Cmd("Set debug to [X10,serial,http,misc,startup,socket,off]");
$v_debug-> set_info('Controls what kind of debug is printed to the console');
if ($state = said $v_debug) {
    $config_parms{debug} = $state;
    $config_parms{debug} = 0 if $state eq 'off';
    speak "Debug has been turned $state";
}

$v_mode = new  Voice_Cmd("Put house in [normal,mute,offline] mode");
$v_mode-> set_info('mute mode disables all speech and sound.  offline disables all serial control');
if ($state = said $v_mode) {
    $Save{mode} = $state;
    speak "The house is now in $state mode.";
    print_log "The house is now in $state mode.";
}

$v_mode_toggle = new  Voice_Cmd("Toggle the house mode");
if (said $v_mode_toggle) {
    if ($Save{mode} eq 'mute') {
        $Save{mode} = 'offline';
    }
    elsif ($Save{mode} eq 'offline') {
        $Save{mode} = 'normal';
    }
    else {
        $Save{mode} = 'mute';
    }
                                # mode => force cause speech even in mute or offline mode
    &speak(mode => 'unmuted', text => "MisterHouse is set to $Save{mode} mode");
}


                                # Search for strings in user code
#&tk_entry('Code Search', \$Save{mh_code_search}, 'Debug flag', \$config_parms{debug});

if (my $string = quotemeta $Tk_results{'Code Search'}) {
    undef $Tk_results{'Code Search'};
    print "Searching for code $string";
    my ($results, $count, %files);
    $count = 0;
    for my $file (sort keys %User_Code) {
        my $n = 0;
        for (@{$User_Code{$file}}) {
            $n++;
            if (/$string/i) {
                $count++;
                $results .= "\nFile: $file:\n------------------------------\n" unless $files{$file}++;
                $results .= sprintf("%4d: %s", $n, $_);
            }
        }
    }
    print_log "Found $count matches";
    $results = "Found $count matches\n" . $results;
    display $results, 60, 'Code Search Results', 'fixed' if $count;
}


                                # Create a list by X10 Addresses
$v_list_x10_items = new Voice_Cmd 'List {X 10,X10} items';
$v_list_x10_items-> set_info('Generates a report fo all X10 items, sorted by device code');
if (said $v_list_x10_items) {
    print_log "Listing X10 items";
    my @object_list = (&list_objects_by_type('X10_Item'),
                       &list_objects_by_type('X10_Appliance'), 
                       &list_objects_by_type('X10_Garage_Door'));
    my @objects = map{&get_object_by_name($_)} @object_list;
    my $results;
    for my $object (sort {$a->{x10_id} cmp $b->{x10_id}} @objects) {
        $results .= sprintf("Address:%-2s  File:%-15s  Object:%s\n",
                            substr($object->{x10_id}, 1), $object->{filename}, $object->{object_name});
    }
    display $results, 60, 'X10 Items', 'fixed';
}

                                # Create a list by Serial States
$v_list_serial_items = new Voice_Cmd 'List serial items';
$v_list_serial_items-> set_info('Generates a report of all Serial_Items, sorted by serial state');
if (said $v_list_serial_items) {
    print_log "Listing serial items";
    my @object_list = &list_objects_by_type('Serial_Item');
    my @objects = map{&get_object_by_name($_)} @object_list;
    my @results;

                                # Sort object by the first id
    for my $object (@objects) {
#        my ($first_id, $states);
        for my $id (sort keys %{$$object{state_by_id}}) {
            push @results, sprintf("ID:%-5s File:%-15s Object:%-15s states: %s",
                                   $id, $object->{filename}, $object->{object_name}, $$object{state_by_id}{$id});
#            $first_id = $id unless $first_id;
#            $states .= "$id=$$object{state_by_id}{$id}, ";
        }
#        push @results, sprintf("ID:%-5s File:%-15s Object:%-15s states: %s",
#                               $first_id, $object->{filename}, $object->{object_name}, $states);
    }
    my $results = join "\n", sort @results;
    display $results, 60, 'Serial Items', 'fixed';
}


                                # Echo serial matches
&Serial_match_add_hook(\&serial_match_log) if $Reload;

sub serial_match_log {
    my ($ref, $state, $event) = @_;
    return unless $event =~ /^X/; # Echo only X10 events
    my $name = substr $$ref{object_name}, 1;
    print_log "$event: $name $state" if $config_parms{x10_errata} > 1;
}

                                # Allow control of individual members

# noloop=start      This directive allows this code to be run on startup/reload

my $code_members_list = join ',', sort keys %Run_Members;
my %code_members_off;

# noloop=stop

if ($Reload) {
    for my $member (split ',', $Save{code_members_off}) {
        print_log "Member $member has been disabled";
        $code_members_off{$member}++;
        $Run_Members{$member} = 0;
    }
}

$v_toggle_run_member = new Voice_Cmd "Toggle code member [$code_members_list]";
$v_toggle_run_member-> set_info('Toggle a code member file on or off');

if (my $member = said $v_toggle_run_member) {
    if ($code_members_off{$member}) {
        print_log "Member $member was toggled On";
        delete $code_members_off{$member};
        $Run_Members{$member} = 1;
    }
    else {
        print_log "Member $member was toggled Off";
        $code_members_off{$member} = 1;
        $Run_Members{$member} = 0;
    }
    $Save{code_members_off} = join ',', sort keys %code_members_off;
}
 
