# Category = iButtons

#@ Adds basic iButton support. See ibutton.pl for configuration info.


=begin comment

 Ray Dzek created a nice 'how to get started with iButton guide' at
    http://www.solarbugs.com/home/ibutton.htm

 Enable iButton support by using these mh.ini parms:
   iButton_tweak         = 0      # Set to 1 to tweak timings if it appears not to work
   iButton_serial_port   = COM1
   iButton_2_serial_port = COM2   # If you have more than one ibutton port
   iButton_3_serial_port = COM2   # If you have more than one ibutton port
   default_temp = Celsius         # If you want to change degress unit from F to C

 You can buy iButton stuff here:
    http://www.iButton.com/index.html
    http://www.pointsix.com
 
 More info on coding iButton_Item is in mh/docs/mh.html

 Specific examples can be found in mh/code/bruce/iButton_bruce.pl

=cut

$v_iButton_connect   = new Voice_Cmd "[Connect,Disconnect] to the iButton bus";
$v_iButton_connect  -> set_info('Use this to free up the serial port or test the iButton start/stop calls');

$v_iButton_list      = new Voice_Cmd "List all the iButton buttons";
$v_iButton_list     -> set_info('Lists the family and ID codes of all the buttons on the bus');
$v_iButton_list     -> set_authority('anyone');

if ($state = said $v_iButton_connect) {
    print "$state the iButton bus";
    if ($state eq 'Connect') {
        print_log &iButton::connect($config_parms{iButton_serial_port});
    }
    else {
        print_log &iButton::disconnect;
    }
}

                                # List all iButton devices
if (said $v_iButton_list) {
    print_log "List of ibuttons:\n" . &iButton::scan_report;
    print_log "List of ibuttons on 2nd ibutton:\n" . &iButton::scan_report(undef, $config_parms{iButton_2_serial_port})
        if $config_parms{iButton_2_serial_port};
}

                                # Pick how often to check the bus ... it takes about 6 ms per device.
                                # You can use the 'start a by name speed benchmark' command
                                # to see how much time this is taking
&iButton::monitor('01') if $New_Second;
&iButton::monitor('01', $config_parms{iButton_2_serial_port} ) if $New_Second and $config_parms{iButton_2_serial_port};
#iButton::monitor if $New_Msecond_500;


# Here are Brian Paulson's notes on how to connect an iButton weather station.

# Note:  In order for read_windspeed to work on Unix, you will need to
#        have Time::HiRes installed.   Not needed on Windows.

# Port is the port that your weather station is connected to.  If your
# weather station is connected to the rest of your 1-wire net, you don't
# need to specify a port because mh will use that by default
# The CHIPS are a listing of all of the chips that make up the weather
# station.  You can get this list by looking at the ini.txt file that
# is generated by the Dallas Semiconductor Weather Station software
# I believe that the first 01 chip should be north and then the rest are
# listed in clockwise order
# By the way, I currently have the Weather Station sitting on my floor
# in the home office because I'm waiting for springtime to mount it outside
# As such, I haven't had a chance to verify that the wind direction and
# wind speed are accurate.

=begin comment 

Since I do not have one of these, I have to leave this commented out

$weather = new iButton::Weather( CHIPS => [ qw( 01000002C77C1FFE
01000002C7681465 01000002C77C12B4 01000002C76CD4E5 01000002C77C1EC9
01000002C76724E7 01000002C761AF69 01000002C7798A76 1D000000010C46AA
1200000013571545 10000000364A826A ) ]);
#				 PORT => $port );
if ($New_Second) {
    if ( $Second == 29) {
	my $temp = $weather->read_temp;
	print "Weather Temp = $temp\n" if defined $temp;
    }
    if ( $Second % 5 == 0 ) {
	my $windspeed = $weather->read_windspeed;
	print "Speed = $windspeed MPH\n" if defined $windspeed;

	my $dir = $weather->read_dir;
	print "Direction = $dir\n" if defined $dir;
    }
}

=cut

