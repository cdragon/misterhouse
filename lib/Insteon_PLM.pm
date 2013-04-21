=begin comment
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

File:
	Insteon_PLM.pm

Description:

	This is the base interface class for Insteon Power Line Modem (PLM)

	For more information regarding the technical details of the PLM:
		http://www.smarthome.com/manuals/2412sdevguide.pdf

Author(s):
    Jason Sharpee / jason@sharpee.com
    Gregg Liming / gregg@limings.net

License:
    This free software is licensed under the terms of the GNU public license. GPLv2

Usage:
	Use these mh.ini parameters to enable this code:

	Insteon_PLM_serial_port=/dev/ttyS4

    Example initialization:


Notes:

Special Thanks to:
    Brian Warren for significant testing and patches
    Bruce Winter - MH

@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@


=cut


package Insteon_PLM;

use strict;
use Insteon;
use Insteon::BaseInterface;
use Insteon::BaseInsteon;
use Insteon::AllLinkDatabase;
use Insteon::MessageDecoder;
use IO::Select;

@Insteon_PLM::ISA = ('Serial_Item','Insteon::BaseInterface');


my %prefix = (
#PLM Serial Commands
                        insteon_received 	=> '0250',
                        insteon_ext_received 	=> '0251',
                        x10_received 		=> '0252',
                        all_link_complete 	=> '0253',
                        plm_button_event 	=> '0254',
                        plm_user_reset		=> '0255',
                        all_link_clean_failed 	=> '0256',
                        all_link_record 	=> '0257',
                        all_link_clean_status 	=> '0258',
                        plm_info 		=> '0260',
                        all_link_send 		=> '0261',
                        insteon_send 		=> '0262',
                        insteon_ext_send	=> '0262',
                        all_link_direct_cleanup => '0262',
                        x10_send 		=> '0263',
                        all_link_start 		=> '0264',
                        all_link_cancel		=> '0265',
			plm_reset 		=> '0267',
                        all_link_first_rec	=> '0269',
                        all_link_next_rec	=> '026a',
			plm_set_config 		=> '026b',
			plm_led_on 		=> '026d',
			plm_led_off 		=> '026e',
                        all_link_manage_rec	=> '026f',
			insteon_nak 		=> '0270',
			insteon_ack 		=> '0271',
			rf_sleep 		=> '0272',
			plm_get_config 		=> '0273'
);
   
my $net_plm_socket = undef;
my $net_plm_socket_select = undef;
my $net_plm_last_reconnect_attempt_time = 0;
my $net_plm_last_ping_time = 0;
my $net_plm_unacknowledged_commands = 0;
my $net_plm_sent_ping_message = 0;

sub startup {
        my $instance = 'Insteon_PLM';
        if(!(defined $net_plm_socket) && (defined $::config_parms{$instance . "_network_address"})) {
                my $host_port = $::config_parms{$instance . "_network_address"};
                my ($host, $port) = $host_port =~ /(\S+)\:(\S+)/;
                $net_plm_socket = new IO::Socket::INET->new(PeerAddr => $host,
                                                 PeerPort => $port,
                                                 Proto => 'tcp'
                                                 # I could add Blocking => 0 here, but from what I've read it's unreliable.
                                                 # http://stackoverflow.com/questions/11895632/recv-blocking-on-perl-even-though-socket-is-non-blocking
                                                 # describes a more reliable method, but I decided to use IO::Select to avoid blocking instead.
                                                 );
                # I stopped using Socket_Item because it doesn't seem to detect disconnection from the PLM
                # under any circumstances I tried.
                # $net_plm_socket = new Socket_Item(undef, undef, $::config_parms{$instance . "_network_address"}, 'insteon_net_plm', 'tcp', 'raw', undef);
                # $net_plm_socket->start;
                if(!$net_plm_socket) {
                        &::print_log("[Insteon_PLM] ERROR: Failed to connect to PLM.");
                        $net_plm_socket = undef;
                        $net_plm_socket_select = undef;
                }
                else {
                        $net_plm_socket->autoflush(1);
                        $net_plm_socket_select = new IO::Select($net_plm_socket);
                        $net_plm_unacknowledged_commands = 0;
                        $net_plm_last_reconnect_attempt_time = time;
                        $net_plm_sent_ping_message = 0;
                        $net_plm_last_ping_time = time;
                }
        }
}

sub connected_to_net_plm {
        my ($self) = @_;
        my $instance = $$self{port_name};
        
        if(!(defined $net_plm_socket) || !$net_plm_socket->connected) {
                return 0;
        }

        # I've read various opinions on the net about the correct way to detect a disconnected
        # socket, from watching for the SIGPIPE signal to calling select->can_read(0) and if
        # it returns true but sysread returns undef, the connection is broken.  From what I've
        # read, TCP expects a periodic ACK packet back whenever it's sent a number of packets,
        # so I don't understand why my tests sending a lot of data to the PLM when it's
        # disconnected never detect the disconnection due to the ACK not coming back.  It
        # might have something to do with using a NAT network connection in the Virtualbox
        # machine running MH.
        # Either way, I've spent far too much time trying all the methods and none of them
        # will tell us if the socket got disconnected by cutting power to the PLM or by
        # leaving its network cable pulled out, at least on my system.
        # $net_plm_socket->connected returns false only under certain limited scenarios I've
        # come up with.
        # A few people on the net will tell you that the only way to detect a socket disconnect
        # under all circumstances is if you send a command and don't get back a response.  So
        # we use $net_plm_unacknowledged_commands to check for that.  Unfortunately, that means
        # users may not detect a disconnect until they happen to send out data, so I also added
        # the option to send a ping every X seconds by defining
        # "Insteon_PLM_network_ping_delay = X"
        if($net_plm_unacknowledged_commands >= 3) {
                # Every PLM command sent should have an immediate response of some sort, even if it's just
                # an echo of the same command or a 15 (PLM too busy).  If we see no response for 2
                # commands in a row, assume the connection is dead.
                &::print_log("[Insteon_PLM] ERROR: Assuming network connection to PLM lost due to timeout responding to commands.");
                $net_plm_socket = undef;
                return 0;
        }
        
        if((defined $::config_parms{$instance . "_network_ping_delay"}) && $::config_parms{$instance . "_network_ping_delay"} > 0) {
                if($net_plm_sent_ping_message) {
                        # We sent a previous ping.  See if it timed out.
                        if($net_plm_last_ping_time < time - 2) {
                                &::print_log("[Insteon_PLM] ERROR: Assuming network connection to PLM lost due to timeout responding to ping.");
                                $net_plm_socket = undef;
                                return 0;
                        }
                }
                elsif($net_plm_last_ping_time < (time - $::config_parms{$instance . "_network_ping_delay"})) {
                        # send_command_to_net_plm will cause connected_to_net_plm to be called
                        # again, so prevent sending the ping again by $net_plm_sent_ping_message = 1;
                        # Doing so also causes connected_to_net_plm to check for timeout on response
                        # to the ping.
                        $net_plm_sent_ping_message = 1;
                        $net_plm_last_ping_time = time;
                        
                        # I'm worried about using PLM firmware version info as a ping request because I
                        # once had a cheap music player corrupt its NVRAM by reading it constantly 24
                        # hours a day as a hold music player.  I don't know about the PLM's NVRAM
                        # quality or type or if it might cache the firmware version in standard RAM,
                        # but if someone sets up a short ping delay I worry we could damage something.
                        # It might be better to try using a '15' message or some other invalid message
                        # as a ping, but I think it would require modifying Message.pm to handle a new
                        # type of message and I don't want to tackle that right now.
                        &::print_log("[Insteon_PLM] DEBUG4: Sending network ping to PLM by requesting its version info.") if( $main::Debug{insteon} >= 4);
                        my $message = new Insteon::InsteonMessage('plm_info', $self);
                        
                        # I tried using the message failure callback system but it is never called when a
                        # a ping has no response.
                        #$message->failure_callback($$self{net_plm_ping_failed});
                        #$message->send_timeout(1);
                	
                	$self->queue_message($message);
                }
        }

        return 1;
}

sub reconnect_to_net_plm {
        my ($self) = @_;
        
        if($self->connected_to_net_plm()) {
                return 1;
        }
        
        # Limit reconnection attempts to once per 10 seconds.
        if($net_plm_last_reconnect_attempt_time < time - 10) {
                if($net_plm_last_reconnect_attempt_time > 0) {
                        # $net_plm_last_reconnect_attempt_time = 0 means we've never been connected before,
                        # in which case we don't show an error that the connection was lost.
                        &::print_log("[Insteon_PLM] ERROR: Network connection to PLM lost, reconnecting...");
                }
                $net_plm_socket = undef;
                startup();
                $net_plm_last_reconnect_attempt_time = time;

                if($self->connected_to_net_plm()) {
                        return 1;
                }
                else {
                        $net_plm_socket = undef;
                }
        }
        return 0;
}

sub send_command_to_net_plm {
        my ($self, $message) = @_;
        
        if(!$self->connected_to_net_plm() && !$self->reconnect_to_net_plm()) {
                return 0;
        }
        if(!$net_plm_socket_select->can_write(0) || !(defined $net_plm_socket->send($message))) {
                # I have never actually hit this point in the code even with the PLM unplugged, 
                # but maybe we'll reach this point under some conditions.
                &::print_log("[Insteon_PLM] ERROR: Send command to PLM failed.  Assuming network connection to PLM lost.");
                $net_plm_socket = undef;
                return 0;
        }
        $net_plm_last_ping_time = time; # Any command we send is considered a ping.
        $net_plm_unacknowledged_commands++;
        return 1;
}



sub serial_startup {
        my ($instance) = @_;
        if(defined $::config_parms{$instance . "_network_address"}) {
                &::print_log( "[Insteon_PLM] WARN: You should not define both Insteon_PLM_network_address and Insteon_PLM_serial_port in your mh.private.ini file."
                        . "  Insteon_PLM_network_address will be used in favor of Insteon_PLM_serial_port." );
        }
        else {
                my $port       = $::config_parms{$instance . "_serial_port"};
                my $speed = 19200;

                &::print_log("[Insteon_PLM] serial:$port:$speed");
                &::serial_port_create($instance, $port, $speed,'none','raw');
        }
}

sub new {
   my ($class, $port_name, $p_deviceid) = @_;
   $port_name = 'Insteon_PLM' if !$port_name;
   my $port       = $::config_parms{$port_name . "_serial_port"};

   my $self = new Insteon::BaseInterface();
   $$self{state}     = '';
   $$self{said}      = '';
   $$self{state_now} = '';
   $$self{port_name} = $port_name;
   $$self{port} = $port;
	$$self{last_command} = '';
	$$self{_prior_data_fragment} = '';
   bless $self, $class;
   $self->restore_data('debug');
   $$self{aldb} = new Insteon::ALDB_PLM($self);

   &Insteon::add($self);

   $self->device_id($p_deviceid) if defined $p_deviceid;

	$$self{xmit_delay} = $::config_parms{Insteon_PLM_xmit_delay};
	$$self{xmit_delay} = 0.25 unless defined $$self{xmit_delay}; # and $$self{xmit_delay} > 0.125;
	&::print_log("[Insteon_PLM] setting default xmit delay to: $$self{xmit_delay}");
	$$self{xmit_x10_delay} = $::config_parms{Insteon_PLM_xmit_x10_delay};
	$$self{xmit_x10_delay} = 0.5 unless defined $$self{xmit_x10_delay} and $$self{xmit_x10_delay} > 0.5;
	&::print_log("[Insteon_PLM] setting x10 xmit delay to: $$self{xmit_x10_delay}");
	$self->_clear_timeout('xmit');
	$self->_clear_timeout('command');

   return $self;
}


sub restore_string
{
	my ($self) = @_;
	my $restore_string = $self->SUPER::restore_string();
	if ($self->_aldb) {
		$restore_string .= $self->_aldb->restore_string();
        }
	return $restore_string;
}

sub check_for_data {
        my ($self) = @_;
        my $data = '';

        my $port_name = $$self{port_name};
        my $instance = $port_name;
      	        
        if(defined $::config_parms{$instance . "_network_address"}) {
      	        if($self->reconnect_to_net_plm()) {
      	                if($net_plm_socket_select->can_read(0)) {
                                my $result = $net_plm_socket->recv($data, 256);
                                if(!(defined $result)) {
                                        # I have never actually hit this point in the code even with the PLM unplugged, 
                                        # but maybe we'll reach this point under some conditions.
                                        &::print_log("[Insteon_PLM] ERROR: Receive command from PLM failed.  Assuming network connection to PLM lost.");
                                        $net_plm_socket = undef;
                                }
                                elsif($data) {
                                        # Assume any response from the PLM means the connection is still working, so
                                        # clear $net_plm_unacknowledged_commands
                                        $net_plm_unacknowledged_commands = 0;
                                        $net_plm_sent_ping_message = 0;
                                }
                         }
        	}
        }
        else {
              	my $port_name = $$self{port_name};
      	        &::check_for_generic_serial_data($port_name) if $::Serial_Ports{$port_name}{object};
      	        $data = $::Serial_Ports{$port_name}{data};
        }
      	
        # always check for data first; if it exists, then process; otherwise check if pending commands exist
        if ($data)
        {
                if(!(defined $net_plm_socket)) {
                	# now, clear the serial port data so that any subsequent command processing doesn't result in an immediate filling/overwriting
	                if (length($$self{_data_fragment}))
                	{
                		# $main::Serial_Ports{$port_name}{data}=pack("H*",$$self{_data_fragment});
			        # always clear the buffer since we're maintaining the fragment separately
                       		$main::Serial_Ports{$port_name}{data} = '';
               		}
               		else
                	{
                		$main::Serial_Ports{$port_name}{data} = '';
                	}
                }
                
         	#lets turn this into Hex. I hate perl binary funcs
        	my $data = unpack "H*", $data;

         	$self->_parse_data($data);
      	}
        elsif (defined $self)
      	{
      	# if no data being received, then check if any timeouts have expired
        	if ($self->_check_timeout('command') == 1)
                {
            		$self->_clear_timeout('command');
            		if ($self->transmit_in_progress) {
#               &::print_log("[Insteon_PLM] WARN: No acknowledgement from PLM to last command requires forced abort of current command."
#                  . " This may reflect a problem with your environment.");
#               pop(@{$$self{command_stack2}}); # pop the active command off the queue
	       			$self->retry_active_message();
               			$self->process_queue();
            		}
                	else
                	{
               			&::print_log("[Insteon_PLM] DEBUG2: PLM command timer expired but no transmission in place.  Moving on...") if $main::Debug{insteon} >= 2;
	       			$self->clear_active_message();
               			$self->process_queue();
            		}
		}
                elsif ($self->_check_timeout('xmit') == 1)
                {
           		$self->_clear_timeout('xmit');
         		if (!($self->transmit_in_progress))
                        {
            			$self->process_queue();
               		}
            	}
	}
}


sub set
{
	my ($self,$p_state,$p_setby,$p_response) = @_;

        my @x10_commands = &Insteon::X10Message::generate_commands($p_state, $p_setby);
        foreach my $command (@x10_commands)
        {
	    $self->queue_message(new Insteon::X10Message($command));
        }
}

sub complete_linking_as_responder
{
	my ($self, $group) = @_;

	# it is not clear that group should be anything as the group will be taken from the controller
	$group = '01' unless $group;
	# set up the PLM as the responder
	my $cmd = '00'; # responder code
	$cmd .= $group; # WARN - must be 2 digits and in hex!!
        my $message = new Insteon::InsteonMessage('all_link_start', $self);
        $message->interface_data($cmd);
	$self->queue_message($message)
}

sub log_alllink_table
{
	my ($self) = @_;
        $self->_aldb->log_alllink_table if $self->_aldb;
}

sub scan_link_table
{
	my ($self,$callback) = @_;
	#$$self{links} = undef; # clear out the old
        $$self{aldb} = new Insteon::ALDB_PLM($self);
	$$self{_mem_activity} = 'scan';
        $$self{_mem_callback} = ($callback) ? $callback : undef;
	$self->_aldb->get_first_alllink();
}

sub initiate_linking_as_controller
{
	my ($self, $group) = @_;

	$group = '01' unless $group;
	# set up the PLM as the responder
	my $cmd = '01'; # controller code
	$cmd .= $group; # WARN - must be 2 digits and in hex!!
        my $message = new Insteon::InsteonMessage('all_link_start', $self);
        $message->interface_data($cmd);
	$self->queue_message($message);
}

sub initiate_unlinking_as_controller
{
	my ($self, $group) = @_;

	$group = 'FF' unless $group;
	# set up the PLM as the responder
	my $cmd = 'FF'; # controller code
	$cmd .= $group; # WARN - must be 2 digits and in hex!!
        my $message = new Insteon::InsteonMessage('all_link_start', $self);
        $message->interface_data($cmd);
	$self->queue_message($message);
}


sub cancel_linking
{
	my ($self) = @_;
	$self->queue_message(new Insteon::InsteonMessage('all_link_cancel', $self));
}

sub _aldb
{
   my ($self) = @_;
   return $$self{aldb};
}



sub _send_cmd {
	my ($self, $message, $cmd_timeout) = @_;
	my $instance = $$self{port_name};
	if(!(defined $net_plm_socket) && !(ref $main::Serial_Ports{$instance}{object})) {
	        if(defined $::config_parms{$instance . "_network_address"}) {
	                $self->reconnect_to_net_plm();
	        }
	        if(!(defined $net_plm_socket)) {
        		print "WARN: Not connected to Insteon PLM via serial port or network interface!\n";
	        	return;
	        }
	}
	unshift(@{$$self{command_history}},$::Time);
	$self->transmit_in_progress(1);

        my $command = $message->interface_data;
	my $delay = $$self{xmit_delay};

        # determine the delay from the point that the message was created to
        # the point that it is queued
        my $incurred_delay_time = $message->seconds_delayed;
        &main::print_log("[Insteon_PLM] DEBUG2: Sending " . $message->to_string . " incurred delay of "
        	. sprintf('%.2f',$incurred_delay_time) . " seconds; starting hop-count: "
                . ((ref $message->setby && $message->setby->isa('Insteon::BaseObject')) ? $message->setby->default_hop_count : "?")) if $main::Debug{insteon} >= 2;

	if ($message->isa('Insteon::X10Message')) { # is x10; so, be slow
        	$command = $prefix{x10_send} . $command;
		$delay = $$self{xmit_x10_delay};
                # clear command timeout so that we don't wait for an insteon ack before sending the next command
	} else {
                my $command_type = $message->command_type;
                $command = $prefix{$command_type} . $command;
                if ($command_type eq 'all_link_send' or $command_type eq 'insteon_send' or $command_type eq 'insteon_ext_send' or $command_type eq 'all_link_direct_cleanup')
                {
         		$self->_set_timeout('command', $cmd_timeout); # a commmand needs to be PLM ack'd w/i 3 seconds or it gets dropped
                }
        }

	&::print_log( "[Insteon_PLM] DEBUG3: Sending PLM raw data: ".lc($command)) if $main::Debug{insteon} >= 3;
	&::print_log( "[Insteon_PLM] DEBUG4:\n".Insteon::MessageDecoder::plm_decode($command)) if $main::Debug{insteon} >= 4;
	my $data = pack("H*",$command);
	
        if(defined $net_plm_socket) {
        	$self->send_command_to_net_plm($data);
        }
        else {
	        $main::Serial_Ports{$instance}{object}->write($data) if $main::Serial_Ports{$instance};
        }

	if ($delay) {
		$self->_set_timeout('xmit',$delay * 1000);
	}
   	$$self{'last_change'} = $main::Time;
}


sub _parse_data {
	my ($self, $data) = @_;
        my ($name, $val);
	
	# it is possible that a fragment exists from a previous attempt; so, if it exists, prepend it
	if ($$self{_data_fragment})
        {
		&::print_log("[Insteon_PLM] DEBUG3: Prepending prior data fragment: $$self{_data_fragment}") if $main::Debug{insteon} >= 3;
                # maintain a copy of the parsed data fragment
		$$self{_prior_data_fragment} = $$self{_data_fragment};
                # append if not a repeat
		$data = $$self{_data_fragment} . $data unless $$self{_data_fragment} eq $data;
                # and, clear it out
		$$self{_data_fragment} = '';
	}
        else
        {
        	# clear the memory of any prior data fragment
                $$self{_prior_data_fragment} = '';
        }

	&::print_log( "[Insteon_PLM] DEBUG3: Received PLM raw data: $data") if $main::Debug{insteon} >= 3;
	&::print_log( "[Insteon_PLM] DEBUG4:\n".Insteon::MessageDecoder::plm_decode($data)) if $main::Debug{insteon} >= 4;

	# begin by pulling out any PLM ack/nacks
	my $prev_cmd = '';
	my $pending_message = $self->active_message;
	if ($pending_message) {
                $prev_cmd = lc $pending_message->interface_data;
		if ($pending_message->isa('Insteon::X10Message'))
                {
        		$prev_cmd = $prefix{x10_send} . $prev_cmd;
       		} else {
               		my $command_type = $pending_message->command_type;
                	$prev_cmd = $prefix{$command_type} . $prev_cmd;
        	}
	}

	my $residue_data = '';
	my $process_next_command = 1;
	my $nack_count = 0;
        my $entered_ack_loop;
        my $previous_parsed_data;
	if (defined $prev_cmd and $prev_cmd ne '')
	{
		my $ackcmd = $prev_cmd . '06';
		my $nackcmd = $prev_cmd . '15';
		my $badcmd = $prev_cmd . '0f';
                $previous_parsed_data = '';
		foreach my $parsed_data (split(/($ackcmd)|($nackcmd)|($prefix{plm_info}\w{12}06)|($prefix{plm_info}\w{12}15)|($badcmd)/,$data))
		{
			#ignore blanks.. the split does odd things
			next if $parsed_data eq '';
                        next if $previous_parsed_data eq $parsed_data; # guard against repeats
                        $previous_parsed_data = $parsed_data; # and, now reinitialize
                        $entered_ack_loop = 1;
			if ($parsed_data =~ /^($ackcmd)|($nackcmd)|($prefix{plm_info}\w{12}06)|($prefix{plm_info}\w{12}15)|($prefix{all_link_first_rec}15)|($prefix{all_link_next_rec}15)|($badcmd)$/)
                        {
				my $ret_code = substr($parsed_data,length($parsed_data)-2,2);
				my $record_type = substr($parsed_data,0,4);
                                my $message_data = substr($parsed_data,4,length($parsed_data)-4);
				if ($ret_code eq '06')
                                {
					if ($record_type eq $prefix{plm_info})
                                        {
						$self->device_id(substr($message_data,0,6));
						$self->firmware(substr($message_data,10,2));
                                                $self->on_interface_info_received();
					}
                                        elsif ($record_type eq $prefix{all_link_first_rec}
                                        		or $record_type eq $prefix{all_link_next_rec})
                                        {
						$$self{_next_link_ok} = 1;
					}
                                        elsif ($record_type eq $prefix{all_link_start})
                                        {
                                                # clear the active message because we're done
                				$self->clear_active_message();
                                        }
                                        else
                                        {
                                        	&::print_log("[Insteon_PLM] DEBUG3: Received PLM acknowledge: "
                                                	. $pending_message->to_string) if $main::Debug{insteon} >= 3;
                                        }

                                        # X10 messages don't ACK back on the powerline, so clear them if the PLM acknowledges
                                        #   AND if the current, pending message is the X10 message
					if (($parsed_data =~ /$prefix{x10_send}\w{4}06/) && ($pending_message->isa('Insteon::X10Message')))
                                        {
                				$self->clear_active_message();
					}

					if ($record_type eq $prefix{all_link_manage_rec})
                                        {
                                                # clear the active message because we're done
                				$self->clear_active_message();

						my $callback;
						if ($self->_aldb->{_success_callback}){
							$callback = $self->_aldb->{_success_callback};
							$self->_aldb->{_success_callback} = undef;
						} elsif ($$self{_mem_callback})
                                                {
							$callback = $pending_message->callback(); #$$self{_mem_callback};
							$$self{_mem_callback} = undef;
                                                }
                                                if ($callback){
							package main;
							eval ($callback);
							&::print_log("[Insteon_PLM] WARN1: Error encountered during ack callback: " . $@)
								if $@ and $main::Debug{insteon} >= 1;
							package Insteon_PLM;	
                                                }
					}
				}
                                elsif ($ret_code eq '15' or $ret_code eq '0f')
                                { #NAK or "bad" command received
                                        $self->clear_active_message(); # regardless, we're not retrying as we'll just get the same

					if ($record_type eq $prefix{all_link_first_rec}
                                        	or $record_type eq $prefix{all_link_next_rec})
                                        {
                                        	# both of these conditions are ok as it just means
                                                # we've reached the end of the memory
						$$self{_next_link_ok} = 0;
						$$self{_mem_activity} = undef;
                                                if ($record_type eq $prefix{all_link_first_rec})
                                                {
                                                	$self->_aldb->health("empty");
                                                }
                                                else
                                                {
                                                	$self->_aldb->health("good");
                                                }
						&::print_log("[Insteon_PLM] " . $self->get_object_name 
							. " completed link memory scan: status: " . $self->_aldb->health())
							if $main::Debug{insteon};
						if ($$self{_mem_callback})
						{
							my $callback = $$self{_mem_callback};
							$$self{_mem_callback} = undef;
							package main;
							eval ($callback);
							&::print_log("[Insteon_PLM] WARN1: Error encountered during nack callback: " . $@)
								if $@ and $main::Debug{insteon} >= 1;
							package Insteon_PLM;
						}
                                        }
                                        elsif ($record_type eq $prefix{all_link_send})
                                        {
                                            	&::print_log("[Insteon_PLM] WARN: PLM memory does not contain link for: "
                                            		. $pending_message->to_string . $@)
                                        }
                                        elsif ($record_type eq $prefix{all_link_start})
                                        {
                                            	&::print_log("[Insteon_PLM] WARN: PLM unable to complete requested operation: "
                                            		. $pending_message->to_string . $@);
                                        }
                                        elsif ($record_type eq $prefix{all_link_manage_rec})
                                        {
                                        	# parse out the data
                                                my $failed_cmd_code = substr($pending_message->interface_data(),0,2);
                                                my $failed_cmd = 'unknown';
                                                if ($failed_cmd_code eq '40')
                                                {
                                                	$failed_cmd = 'update/add controller record';
                                                }
                                                elsif ($failed_cmd_code eq '41')
                                                {
                                                	$failed_cmd = 'update/add responder record';
                                                }
                                                elsif ($failed_cmd_code eq '80')
                                                {
                                                	$failed_cmd = 'delete record';
                                                }
                                                my $failed_group = substr($pending_message->interface_data(),4,2);
                                                my $failed_deviceid = substr($pending_message->interface_data(),6,6);
                                            	&::print_log("[Insteon_PLM] WARN: PLM unable to complete requested "
                                                	. "PLM link table update ($failed_cmd) for "
                                            		. "group: $failed_group and deviceid: $failed_deviceid" );
                                                if ($$self{_mem_callback})
                                        	{
							my $callback = $$self{_mem_callback};
							$$self{_mem_callback} = undef;
							package main;
							eval ($callback);
							&::print_log("[Insteon_PLM] WARN1: Error encountered during ack callback: " . $@)
								if $@ and $main::Debug{insteon} >= 1;
							package Insteon_PLM;
						}
                                                # clear the active message because we're done
                				# $self->clear_active_message();
                                        }
                                        else
                                        {
						&::print_log("[Insteon_PLM] WARN: received NACK from PLM for "
							. $pending_message->to_string());
					}
				}
                                else
                                {
					# We have a problem (Usually we stepped on another X10 command)
					&::print_log("[Insteon_PLM] ERROR: encountered $parsed_data. "
                                        	. $pending_message->to_string());
                                        $self->active_message->no_hop_increase(1);
					$self->retry_active_message();
					#move it off the top of the stack and re-transmit later!
					#TODO: We should keep track of an errored command and kill it if it fails twice.  prevent an infinite loop here
				}
			}
                        else  # no match occurred--which is the "leftovers"
                        {
                        	# is $parsed_data an accidental anomoly? (there are other cases; but, this is a good start)
                                if ($parsed_data =~ /^($prefix{insteon_send}\w{12}06)|($prefix{insteon_send}\w{12}15)$/)
                                {
                                	# first, parse the content to confirm that it could be a legitimate ACK
                                        my $unknown_deviceid = substr($parsed_data,4,6);
                                        my $unknown_msg_flags = substr($parsed_data,10,2);
                                        my $unknown_command = substr($parsed_data,12,2);
                                        my $unknown_data = substr($parsed_data,14,2);
                                        my $unknown_obj = &Insteon::get_object($unknown_deviceid, '01');
                                        if ($unknown_obj)
                                        {
                                        	&::print_log("[Insteon_PLM] WARN: encountered '$parsed_data' "
                                                	. "from " . $unknown_obj->get_object_name()
                                                        . " with command: $unknown_command, but expected '$ackcmd'.");
				       		$residue_data .= $parsed_data;
                                        }
                                        else
                                        {
                                        	&::print_log("[Insteon_PLM] ERROR: encountered '$parsed_data' "
                                                	. "that does not match any known device ID (expected '$ackcmd')."
                                                        . " Discarding received data.");
				       		#$residue_data .= $parsed_data;
                                        }
                                        $self->active_message->no_hop_increase(1);
                                }
                                else
                                {
					$residue_data .= $parsed_data;
                                }
			}
		}  #foreach - split across the incoming data

		$residue_data = $data unless $entered_ack_loop or $residue_data;
	}
        else
        {
		$residue_data = $data unless $residue_data;
	}

        my $entered_rcv_loop = 0;

        $previous_parsed_data = '';

	foreach my $parsed_data (split(/($prefix{x10_received}\w{4})|($prefix{insteon_received}\w{18})|($prefix{insteon_ext_received}\w{46})|($prefix{all_link_complete}\w{16})|($prefix{all_link_clean_failed}\w{8})|($prefix{all_link_record}\w{16})|($prefix{all_link_clean_status}\w{2})|($prefix{plm_button_event}\w{2})|($prefix{plm_user_reset})/,$residue_data))
	{
		#ignore blanks.. the split does odd things
		next if $parsed_data eq '';
                next if $previous_parsed_data eq $parsed_data; # guard against repeats
                $previous_parsed_data = $parsed_data; # and, now reinitialize

                $entered_rcv_loop = 1;

                my $parsed_prefix = substr($parsed_data,0,4);
                my $message_length = length($parsed_data);

        	my $message_data = substr($parsed_data,4,length($parsed_data)-4);

		if ($parsed_prefix eq $prefix{insteon_received} and ($message_length == 22))
                { #Insteon Standard Received
                        $self->on_standard_insteon_received($message_data);
		}
                elsif ($parsed_prefix eq $prefix{insteon_ext_received} and ($message_length == 50))
                { #Insteon Extended Received
                	$self->on_extended_insteon_received($message_data);
		}
                elsif($parsed_prefix eq $prefix{x10_received} and ($message_length == 8))
                { #X10 Received
                       	my $x10_message = new Insteon::X10Message($message_data);
                        my $x10_data = $x10_message->get_formatted_data();
			&::print_log("[Insteon_PLM] DEBUG3: received x10 data: $x10_data") if $main::Debug{insteon} >= 3;
			&::process_serial_data($x10_data,undef,$self);
		}
                elsif ($parsed_prefix eq $prefix{all_link_complete} and ($message_length == 20))
                { #ALL-Linking Completed
			my $link_address = substr($message_data,4,6);
			&::print_log("[Insteon_PLM] DEBUG2: ALL-Linking Completed with $link_address ($message_data)") if $main::Debug{insteon} >= 2;
                        $self->clear_active_message();
		}
                elsif ($parsed_prefix eq $prefix{all_link_clean_failed} and ($message_length == 12))
                { #ALL-Link Cleanup Failure Report
                        # extract out the pertinent parts of the message for display purposes
                        # bytes 0-1 - group; 2-7 device address
                        my $failure_group = substr($message_data,0,2);
                        my $failure_device = substr($message_data,2,6);

			&::print_log("[Insteon_PLM] DEBUG2: Received all-link cleanup failure from device: "
                        	. "$failure_device and group: $failure_group") if $main::Debug{insteon} >= 2;
                        
                        my $failed_object = &Insteon::get_object($failure_device,'01');
                        my $message = new Insteon::InsteonMessage('all_link_direct_cleanup', $failed_object, 
                        	$self->active_message->command, $failure_group);
                        push(@{$$failed_object{command_stack}}, $message);
                        $failed_object->_process_command_stack();
                        
		}
                elsif ($parsed_prefix eq $prefix{all_link_record} and ($message_length == 20))
                { #ALL-Link Record Response
			&::print_log("[Insteon_PLM] DEBUG2: ALL-Link Record Response:$message_data") if $main::Debug{insteon} >= 2;
			$self->_aldb->parse_alllink($message_data);
        		# before doing the next, make sure that the pending command
                        #   (if it sitll exists) is pulled from the queue
                        $self->clear_active_message();

			$self->_aldb->get_next_alllink();
		}
		elsif ($parsed_prefix eq $prefix{plm_user_reset} and ($message_length == 4))
		{
			main::print_log("[Insteon_PLM] Detected PLM user reset to factory defaults");
		}
                elsif ($parsed_prefix eq $prefix{all_link_clean_status} and ($message_length == 6))
                { #ALL-Link Cleanup Status Report
			my $cleanup_ack = substr($message_data,0,2);
			if ($cleanup_ack eq '15')
                        {
				&::print_log("[Insteon_PLM] WARN1: All-link cleanup failure for scene: "
                                	. $self->active_message->setby->get_object_name . ". Retrying in 1 second.")
					if $main::Debug{insteon} >= 1;
                                $self->retry_active_message();
                                # except that we should cause a bit of a delay to let things settle out
				$self->_set_timeout('xmit', 1000);
				$process_next_command = 0;
			}
                        else
                        {
                        	my $message_to_string = ($self->active_message) ? $self->active_message->to_string() : "";
				&::print_log("[Insteon_PLM] Received all-link cleanup success: $message_to_string")
                                	if $main::Debug{insteon};
                                $self->clear_active_message();
			}
		}
                elsif (substr($parsed_data,0,2) eq '15')
                { # Indicates that the PLM can't receive more commands at the moment
                  # so, slow things down
			if (!($nack_count))
                        {
				my $nack_delay = ($::config_parms{Insteon_PLM_disable_throttling}) ? 0.3 : 1.0;
				&::print_log("[Insteon_PLM] DEBUG3: Interface extremely busy. Resending command"
					. " after delaying for $nack_delay second") if $main::Debug{insteon} >= 3;
				$self->_set_timeout('xmit',$nack_delay * 1000);
				$self->active_message->no_hop_increase(1);
                                $self->retry_active_message();
				$process_next_command = 0;
				$nack_count++;
			}
		}
                else
                {
			# it's probably a fragment; so, handle it
                        # it it's the same as last time, then drop it as we can't recover
			unless (($parsed_data eq $$self{_prior_data_fragment}) or ($parsed_data eq $$self{_data_fragment})) {
				$$self{_data_fragment} .= $parsed_data;
				main::print_log("[Insteon_PLM] DEBUG3: Saving parsed data fragment: " 
					. $parsed_data) if( $main::Debug{insteon} >= 3);
			}
		}
	}

	unless( $entered_rcv_loop or $$self{_data_fragment}) {
		$$self{_data_fragment} = $residue_data;
		main::print_log("[Insteon_PLM] DEBUG3: Saving residue data fragment: " 
			. $residue_data) if( $residue_data and $main::Debug{insteon} >= 3);
	}

	if ($process_next_command) {
 		$self->process_queue();
	}

	return;
}

# dummy sub required to support the X10 integrtion

sub add_id_state {
   # do nothing
}

sub firmware {
	my ($self, $p_firmware) = @_;
	$$self{firmware} = $p_firmware if defined $p_firmware;
	return $$self{firmware};
}


1;