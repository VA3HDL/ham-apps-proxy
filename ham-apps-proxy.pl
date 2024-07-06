#!/usr/bin/perl

use strict;
use warnings;

$| = 1;

my $VER         = '24.05.25';
my $ETIMEDOUT   = 260;
my $EWOULDBLOCK = 11;

=pod
HAM-APPS-PROXY  --  a HTTP => TCP/UDP/other proxy for Ham Radio applications.

Provide easy HTTP endpoints to hit various interfaces.

Author: David Westbrook K2DW
Contact: dwestbrook@gmail.com or K2DW on POTA Slack workspace.

Support: Direct message or #proj-potaplus-browser-extension channel on POTA Slack workspace

ORIGINAL: Source & Documentation:
	https://dwestbrook.net/projects/potaplus

FORK by VA3HDL:
    https://github.com/VA3HDL/browsercat
    
=cut

=pod
cpanm PAR::Packer
cpanm Win32::OLE
cpanm IO::Socket::Timeout
cpanm HTTP::Server::Simple::CGI
pp -o ham-apps-proxy.exe -M IO::Socket::INET -M IO::Socket::Timeout -M Errno -M CGI -M HTTP::Server::Simple::CGI -M Win32::OLE ham-apps-proxy.pl

read registry to get the DXK/CMD port numbers
cmd-line options for  host, port #s

Read registry to find "POTA" UDF and/or cmdline option for it.
App_DXKeeper_User_Defined_0
=cut

{

    package MyWebServer;
    use HTTP::Server::Simple::CGI;
    use base qw(HTTP::Server::Simple::CGI);
    use Data::Dumper;
    use IO::Socket::INET;
    use IO::Socket::Timeout;
    use Errno qw(ETIMEDOUT EWOULDBLOCK);
    use File::Basename;

    # use Win32::OLE;
    use Hamlib;
    print "Perl $], $Hamlib::hamlib_version\n";

    #Hamlib::rig_set_debug($Hamlib::RIG_DEBUG_TRACE);
    Hamlib::rig_set_debug($Hamlib::RIG_DEBUG_NONE);
    my $rig      = new Hamlib::Rig(2);
    my $old_host = '';
    my $old_port = 0;

    my %dispatch = (

        # omit trailing / on key names
        '/version' => \&resp_version,

        # LOGGING and RIG CONTROL
        '/aclog' => \&resp_aclog,

        # LOGGING
        '/dxlab/dxkeeper' => \&resp_dxkeeper,
        '/log4om'         => \&resp_log4om,
        '/logger32'       => \&resp_logger32,
        '/cqrlog'         => \&resp_cqrlog,

        # RIG CONTROL
        '/dxlab/commander' => \&resp_commander,
        '/omnirig'         => \&resp_omnirig,
        '/rigctl'          => \&resp_rigctl,

        # ROTOR CONTROL
        '/pst'    => \&resp_pst,
        '/rotctl' => \&resp_rotctl,
    );

    sub stamp {
        return scalar localtime() . ": ";
    }

    sub handle_request {
        my $self = shift;
        my $cgi  = shift;

        my $path = $cgi->path_info();
        my $handler;
        while ( !$handler && $path ) {
            $handler = $dispatch{$path};
            last unless $path =~ m#/#;
            $path =~ s#/[^/]*$##;
        }

        if ( $cgi->request_method eq 'OPTIONS' ) {

            # Handle OPTIONS request
            print $cgi, 200, [
                'Access-Control-Allow-Origin' =>
                  '*',    # Replace "*" with the appropriate origin
                'Access-Control-Allow-Methods' =>
                  'GET, POST, OPTIONS',    # Include the allowed methods
                'Access-Control-Allow-Headers' => 'Content-Type'
                ,    # Include any additional headers used in the request
                'Content-Length' => 0,
                'Content-Type'   => 'text/plain',
            ];
            return;
        }

        if ( ref($handler) eq "CODE" ) {
            print "HTTP/1.0 200 OK\r\n";
            $handler->($cgi);
        }
        else {
            print "HTTP/1.0 404 Not found\r\n";
            print $cgi->header,
              $cgi->start_html('Not found'),
              $cgi->h1( 'Not found: ' . $cgi->path_info ),
              $cgi->end_html;

            # close $cgi->stdio_handle;
            close $cgi->stdin_handle;
            close $cgi->stdout_handle;
        }
    }

    sub ADIF {
        my ( $k, $v ) = @_;
        return sprintf '<%s:%d>%s', $k, length($v), $v;
    }

    sub writeINET {
        my ( $proto, $host, $port, $msg ) = @_;
        my $socket = new IO::Socket::INET(
            PeerHost => $host,
            PeerPort => $port,
            Proto    => $proto,
            Timeout  => 2,
        );
        warn "writeINET [$proto:$host:$port] CANNOT CONNECT: $!" if !$socket;
        return 0, "cannot connect to the server $!" unless $socket;
        IO::Socket::Timeout->enable_timeouts_on($socket);
        $socket->write_timeout(0.25);
        $socket->read_timeout(0.25);

        warn stamp, "writeINET [$proto:$host:$port] $msg";
        print $socket $msg;

        #    $socket->shutdown(SHUT_WR);
        #warn "reading...";
        my $response = "";
        $response .= $_ while <$socket>;

        #    my $response = <$socket>;
        #warn "done.";
        if ( !$response && ( 0 + $! == $ETIMEDOUT || 0 + $! == $EWOULDBLOCK ) )
        {
            #warn "READ TIMEOUT";
            return 0, "timeout reading on the socket";
        }

        #    $socket->shutdown(SHUT_RDWR);
        return 1, $response;
    }

    sub resp_version {
        my $cgi = shift;    # CGI.pm object
        return if !ref $cgi;

        print $cgi->header(
            -type                        => 'application/json',
            -nph                         => 1,
            -status                      => 200,
            -Access_Control_Allow_Origin => '*',
        );
        print qq!{"version":"$VER"}!;
    }

# http://localhost:8073/dxlab/commander/CmdSetFreqMode?xcvrfreq=14080&xcvrmode=RTTY&preservesplitanddual=N
# ORDER MATTERS for the parameters ... Commander parsing seems strict on the payload order (even though it's ADIF)
    sub resp_commander {

        # http://www.dxlabsuite.com/commander/Commander%20TCPIP%20Messages.pdf
        my $cgi = shift;    # CGI.pm object
        return if !ref $cgi;

        my $command = ( split '/', $cgi->path_info )[-1];
        my @k       = grep { !/^__/ } $cgi->param;
        return if !scalar @k;    # no params
        my %p    = $cgi->Vars;
        my $host = delete $p{__host} || 'localhost';
        my $port = delete $p{__port} || 52002;

#    $p{xcvrmode} = $p{xcvrfreq} >= 10000 ? 'USB' : 'LSB' if $p{xcvrfreq} && $p{xcvrmode} eq 'SSB';
        my $parameters = join '', map { ADIF( $_, $p{$_} ) } @k

          #      sort keys %p
          ;
        $parameters .= '<EOR>';
        my $msg = join '', ADIF( 'command', $command ),
          ADIF( 'parameters', $parameters );
        my ( $ok, $response ) = writeINET( 'tcp', $host, $port, $msg );

        print $cgi->header(
            -type                        => 'text/plain',
            -nph                         => 1,
            -status                      => ( $ok ? 200 : 500 ),
            -Access_Control_Allow_Origin => '*',
        );
        print $response;
    }

# http://localhost:8073/dxlab/dxkeeper/log?CALL=P5DX&RST_SENT=599&RST_RCVD=599&FREQ=1.84027&BAND=160M&MODE=CW&QSO_DATE=20170515&TIME_ON=210700&STATION_CALLSIGN=AA6YQ&TX_PWR=1500
    sub resp_dxkeeper {

#  http://www.dxlabsuite.com/dxkeeper/DXKeeper%20TCPIP%20Messages%20v1.pdf
#  <command:3>log<parameters:170><CALL:4>P5DX <RST_SENT:3>599 <RST_RCVD:3>599
#	<FREQ:7>1.84027 <BAND:4>160M <MODE:2>CW <QSO_DATE:8>20170515 <TIME_ON:6>210700
#	<STATION_CALLSIGN:5>AA6YQ <TX_PWR:4>1500 <EOR>
        my $cgi = shift;    # CGI.pm object
        return if !ref $cgi;

        my $command = ( split '/', $cgi->path_info )[-1];
        my @k       = grep { !/^__/ } $cgi->param;
        return if !scalar @k;    # no params
        my %p          = $cgi->Vars;
        my $host       = delete $p{__host} || 'localhost';
        my $port       = delete $p{__port} || 52001;
        my $parameters = join '', map { ADIF( $_, $p{$_} ) } @k

          #      sort keys %p
          ;
        $parameters .= '<EOR>';
        my $msg = join '', ADIF( 'command', $command ),
          ADIF( 'parameters', $parameters );
        my ( $ok, $response ) = writeINET( 'tcp', $host, $port, $msg );

        print $cgi->header(
            -type   => 'text/plain',
            -nph    => 1,
            -status => ( $ok ? 200 : 500 ),
        );
        print $response;
    }

    # http://localhost:8073/omnirig/qsy?freq=7200000&mode=LSB
    sub resp_omnirig {
        my $cgi = shift;    # CGI.pm object
        return if !ref $cgi;

        my @k = grep { !/^__/ } $cgi->param;
        return if !scalar @k;    # no params

        my $objectId =
          $cgi->param('__host') || '0839E8C6-ED30-4950-8087-966F970F0CAE';
        my $rigName = $cgi->param('__port') || 'Rig1';
        print "OmniRig '$rigName' [$objectId]\n";

        eval {
            # {0839E8C6-ED30-4950-8087-966F970F0CAE}
            # OmniRig.OmniRigX
            my $OmniRig;

            # use existing instance if OmniRig is already running
            eval { $OmniRig = Win32::OLE->GetActiveObject("{$objectId}") };
            die "OmniRig not installed" if $@;
            $OmniRig ||= eval {
                Win32::OLE->new( "{$objectId}", sub { $_[0]->Quit; } );
            } or do {
                warn "Oops, cannot start OmniRig";
                print $cgi->header(
                    -type                        => 'text/plain',
                    -nph                         => 1,
                    -status                      => 500,
                    -Access_Control_Allow_Origin => '*',
                );
                return;
            };

            my %modes = (
                USB      => 0x02000000,
                LSB      => 0x04000000,
                'DATA-U' => 0x08000000,
                'DATA-L' => 0x10000000,
                AM       => 0x20000000,
                FM       => 0x40000000,
                CW       => 0x00800000,
                'CW-U'   => 0x00800000,
                'CW-L'   => 0x01000000,
            );
            $modes{SSB}  = $modes{USB};
            $modes{DATA} = $modes{'DATA-U'};
            my $freq     = $cgi->param('freq');            # Hz
            my $mode     = $cgi->param('mode') || 'USB';
            my $modeCode = $modes{$mode};
            warn stamp, @_,
              " OmniRig $rigName QSY == $freq Hz == $mode ($modeCode)\n";

# order matters -- change mode first, then freq. Because the mode might carry an offset in omnirig/radio.
            $OmniRig->$rigName->{Mode}  = $modeCode;
            $OmniRig->$rigName->{FreqA} = $freq;

            undef $OmniRig;                                # destroy OmniRig
            print $cgi->header(
                -type                        => 'text/plain',
                -nph                         => 1,
                -status                      => 200,
                -Access_Control_Allow_Origin => '*',
            );
        }
          or warn Dumper( $objectId, $rigName, $cgi->path_info, { $cgi->Vars },
            $@, );
    }

=pod
OMNIRIG CONSTANTS
  PM_UNKNOWN = $00000001;
  PM_FREQ = $00000002;
  PM_FREQA = $00000004;
  PM_FREQB = $00000008;
  PM_PITCH = $00000010;
  PM_RITOFFSET = $00000020;
  PM_RIT0 = $00000040;
  PM_VFOAA = $00000080;
  PM_VFOAB = $00000100;
  PM_VFOBA = $00000200;
  PM_VFOBB = $00000400;
  PM_VFOA = $00000800;
  PM_VFOB = $00001000;
  PM_VFOEQUAL = $00002000;
  PM_VFOSWAP = $00004000;
  PM_SPLITON = $00008000;
  PM_SPLITOFF = $00010000;
  PM_RITON = $00020000;
  PM_RITOFF = $00040000;
  PM_XITON = $00080000;
  PM_XITOFF = $00100000;
  PM_RX = $00200000;
  PM_TX = $00400000;
  PM_CW_U = $00800000;
  PM_CW_L = $01000000;
  PM_SSB_U = $02000000;
  PM_SSB_L = $04000000;
  PM_DIG_U = $08000000;
  PM_DIG_L = $10000000;
  PM_AM = $20000000;
  PM_FM = $40000000;
=cut

# http://localhost:8073/log4om/log?CALL=P5DX&RST_SENT=599&RST_RCVD=599&FREQ=1.84027&BAND=160M&MODE=CW&QSO_DATE=20170515&TIME_ON=210700&STATION_CALLSIGN=AA6YQ&TX_PWR=1500
    sub resp_log4om {
        my $cgi = shift;
        return if !ref $cgi;

        my $command    = ( split '/', $cgi->path_info )[-1];
        my @k          = grep { !/^__/ } $cgi->param;
        my %p          = $cgi->Vars;
        my $host       = delete $p{__host} || 'localhost';
        my $port       = delete $p{__port} || 2239;
        my $parameters = join '', map { ADIF( $_, $p{$_} ) } @k;
        $parameters .= '<EOR>';
        my $msg = join '', ADIF( 'command', $command ),
          ADIF( 'parameters', $parameters );
        my ( $ok, $response ) = writeINET( 'udp', $host, $port, $msg );

        print $cgi->header(
            -type                        => 'text/plain',
            -nph                         => 1,
            -status                      => ( $ok ? 200 : 500 ),
            -Access_Control_Allow_Origin => '*',
        );
        print $response;
    }

    sub MARKUPTAG {
        my ( $k, $v ) = @_;
        return sprintf '<%s>%s</%s>', $k, $v, $k;
    }

    sub VALUETAG {
        my ( $k, $v ) = @_;
        return sprintf '%s', $k;
    }

# http://localhost:8073/aclog/updateandlog?CALL=WC3N&BAND=20&MODE=FT8&FREQ=14.074&RSTR=599&RSTS=488&GRID=FM19&POWER=100&DATE=2021/04/25&TIMEON=12:34&TIMEOFF=13:03
# http://localhost:8073/aclog/changefreq?value=21.446&suppressmodedefault=TRUE
# http://localhost:8073/aclog/changemode?value=RTTY
    sub resp_aclog {

# http://www.n3fjp.com/help/api.html
# requires v1.7 for <UPDATEANDLOG>
# <CMD><UPDATEANDLOG><CALL>WC3N</CALL><BAND>20</BAND><MODE>FT8</MODE><FREQ>14.074<RSTR>599</RSTR><RSTS>488</RSTS><GRID>FM19</GRID><POWER>100</POWER><DATE>2021/04/25</DATE><TIMEON>12:34</TIMEON><TIMEOFF>13:03</TIMEOFF></CMD>

# <CMD><CHANGEFREQ><VALUE>21.446</VALUE><SUPPRESSMODEDEFAULT>TRUE</SUPPRESSMODEDEFAULT></CMD>
# <CMD><CHANGEMODE><VALUE>RTTY</VALUE></CMD>
        my $cgi = shift;
        return if !ref $cgi;

        my $command    = ( split '/', $cgi->path_info )[-1];
        my @k          = grep { !/^__/ } $cgi->param;
        my %p          = $cgi->Vars;
        my $host       = delete $p{__host} || 'localhost';
        my $port       = delete $p{__port} || 1100;
        my $parameters = join '', map { MARKUPTAG( uc($_), $p{$_} ) } @k;
        my $msg =
          MARKUPTAG( 'CMD', "<" . uc($command) . ">$parameters" ) . "\r\n";
        my ( $ok, $response ) = writeINET( 'tcp', $host, $port, $msg );

        print $cgi->header(
            -type                        => 'text/plain',
            -nph                         => 1,
            -status                      => ( $ok ? 200 : 500 ),
            -Access_Control_Allow_Origin => '*',
        );
        print $response;
    }

    sub resp_cqrlog {
        my $cgi = shift;
        return if !ref $cgi;

        my $command = ( split '/', $cgi->path_info )[-1];
        my @k       = grep { !/^__/ } $cgi->param;
        my %p       = $cgi->Vars;
        my $host    = delete $p{__host} || 'localhost';
        my $port    = delete $p{__port} || 2333;
        my $msg     = join '', map { ADIF( $_, $p{$_} ) } @k;
        $msg .= '<EOR>';

        my ( $ok, $response ) = writeINET( 'udp', $host, $port, $msg );

        print $cgi->header(
            -type                        => 'text/plain',
            -nph                         => 1,
            -status                      => ( $ok ? 200 : 500 ),
            -Access_Control_Allow_Origin => '*',
        );
        print $response;

        # Log ADIF to file for backup purposes

        my $script_path = dirname(__FILE__);   # Get the script's directory path
            # my $filename = "$script_path/myfile.txt";  # Create the file path
        my $filename = "$script_path/logfile.adi";
        open( my $fh, '>>:encoding(UTF-8)', $filename )
          or die "Could not open file '$filename'";
        print $fh join '', ADIF( 'log', $msg ), "\n";
        close $fh;
    }

=pod

d8888b. d888888b  d888b   .o88b. d888888b db
88  `8D   `88'   88' Y8b d8P  Y8 `~~88~~' 88
88oobY'    88    88      8P         88    88
88`8b      88    88  ooo 8b         88    88
88 `88.   .88.   88. ~8~ Y8b  d8    88    88booo.
88   YD Y888888P  Y888P   `Y88P'    YP    Y88888P

=cut

    sub resp_rigctl {
        # Example requests:
        # set freq http://localhost:8073/rigctl/F?14248000&__port=4531
        # set mode http://localhost:8073/rigctl/M?USB%202800&__port=4531
        # get freq http://localhost:8073/rigctl/f?&__port=4531
        # get az&el http://localhost:8073/rotctl/p?&__port=4535
        #
        my $cgi = shift;
        return if !ref $cgi;

        my $command = ( split '/', $cgi->path_info )[-1];
        my @k       = grep { !/^__/ } $cgi->param;
        my %p       = $cgi->Vars;
        my $host    = delete $p{__host} || 'localhost';
        my $port    = delete $p{__port} || 4532;

        warn "\n", stamp, "► RIGCTL Path: ", $cgi->path_info, " ► Command: ",
          $command, " ► k: ", @k, " ► p: ", %p;

        if ( $old_host eq '' || $old_port eq 0 ) {

            # warn stamp, "RIGCTL rig not open";
            $old_host = $host;
            $old_port = $port;
            $rig->set_conf( "rig_pathname", "$host:$port" );
            $rig->open();
        }
        else {
            # warn stamp, "RIGCTL rig defined";
        }

        if ( $old_host ne $host || $old_port ne $port ) {

            # warn stamp, "RIGCTL rig pathname changed $old_host:$old_port to $host:$port";
            $old_host = $host;
            $old_port = $port;
            $rig->close();
            $rig->set_conf( "rig_pathname", "$host:$port" );
            $rig->open();
        }
        else {
            # warn stamp, "RIGCTL rig pathname no change";
        }

        my %modes = (
            SSB      => $Hamlib::RIG_MODE_USB,
            USB      => $Hamlib::RIG_MODE_USB,
            LSB      => $Hamlib::RIG_MODE_LSB,
            DATA     => $Hamlib::RIG_MODE_PKTUSB,
            'DATA-U' => $Hamlib::RIG_MODE_PKTUSB,
            'DATA-L' => $Hamlib::RIG_MODE_PKTLSB,
            AM       => $Hamlib::RIG_MODE_AM,
            FM       => $Hamlib::RIG_MODE_FM,
            CW       => $Hamlib::RIG_MODE_CW,
            'CW-U'   => $Hamlib::RIG_MODE_CW,
            'CW-L'   => $Hamlib::RIG_MODE_CWR,
        );

        # $modes{SSB}  = $modes{USB};
        # $modes{DATA} = $modes{'DATA-U'};
        my $parameters = join '', map { VALUETAG( $_, $p{$_} ) } @k;

        # Define the mode map
        my %mode_map = (
            $Hamlib::RIG_MODE_NONE    => 'NONE',
            $Hamlib::RIG_MODE_AM      => 'AM',
            $Hamlib::RIG_MODE_CW      => 'CW',
            $Hamlib::RIG_MODE_CWR     => 'CWR',
            $Hamlib::RIG_MODE_LSB     => 'LSB',
            $Hamlib::RIG_MODE_USB     => 'USB',
            $Hamlib::RIG_MODE_FM      => 'FM',
            $Hamlib::RIG_MODE_WFM     => 'WFM',
            $Hamlib::RIG_MODE_RTTY    => 'RTTY',
            $Hamlib::RIG_MODE_RTTYR   => 'RTTYR',
            $Hamlib::RIG_MODE_PKTLSB  => 'PKTLSB',
            $Hamlib::RIG_MODE_PKTUSB  => 'PKTUSB',
            $Hamlib::RIG_MODE_PKTFM   => 'PKTFM',
            $Hamlib::RIG_MODE_ECSSLSB => 'ECSSLSB',
            $Hamlib::RIG_MODE_ECSSUSB => 'ECSSUSB',
            $Hamlib::RIG_MODE_FMN     => 'FMN',
            $Hamlib::RIG_MODE_DSB     => 'DSB',
        );

        if ( $command eq "f" ) {

            my $freq = $rig->get_freq($Hamlib::RIG_VFO_CURR) / 1000000;
            (my $mode, my $width) = $rig->get_mode($Hamlib::RIG_VFO_CURR);
            my $mode_text = $mode_map{$mode} // 'UNKNOWN';
            warn stamp, "VFO Freq: $freq", " VFO Mode: $mode_text", " VFO Width: $width";

            print $cgi->header(
                -type                        => 'application/json',
                -nph                         => 1,
                -status                      => 200,
                -Access_Control_Allow_Origin => '*',
            );
            print qq!{"frequency":"$freq","mode":"$mode_text","width":"$width"}!;
        }

        if ( $command eq "F" && $parameters gt 0 ) {
            warn stamp, "RIGCTL Command: $command Value: $parameters";
            $rig->set_freq( $Hamlib::RIG_VFO_CURR, $parameters );

            my ( $ok, $response ) = ( 200, "Success" );
            print $cgi->header(
                -type                        => 'text/plain',
                -nph                         => 1,
                -status                      => ( $ok ? 200 : 500 ),
                -Access_Control_Allow_Origin => '*',
            );
            print $response;
        }

        if ( $command eq "M" && $parameters gt 0 ) {
            my $mode     = ( split ' ', $parameters )[0];
            my $modeCode = $modes{$mode};
            my $bw       = ( split ' ', $parameters )[-1];
            warn stamp, "RIGCTL Command: $command Value: $parameters Mode: $mode ModeCode: $modeCode Bandwidth: $bw";
            $rig->set_mode( $modeCode, $bw, $Hamlib::RIG_VFO_CURR );

            my ( $ok, $response ) = ( 200, "Success" );
            print $cgi->header(
                -type                        => 'text/plain',
                -nph                         => 1,
                -status                      => ( $ok ? 200 : 500 ),
                -Access_Control_Allow_Origin => '*',
            );
            print $response;
        }

    }

# http://localhost:8073/logger32/log?CALL=P5DX&RST_SENT=599&RST_RCVD=599&FREQ=1.84027&BAND=160M&MODE=CW&QSO_DATE=20170515&TIME_ON=210700&STATION_CALLSIGN=AA6YQ&TX_PWR=1500
    sub resp_logger32 {

   # https://www.logger32.net/files/Logger32_v4_User_Manual.pdf	Sections 31 & 32
        my $cgi = shift;    # CGI.pm object
        return if !ref $cgi;

        my $command    = ( split '/', $cgi->path_info )[-1];
        my @k          = grep { !/^__/ } $cgi->param;
        my %p          = $cgi->Vars;
        my $host       = delete $p{__host} || 'localhost';
        my $port       = delete $p{__port} || 52001;
        my $parameters = join '', map { ADIF( $_, $p{$_} ) } @k

          #      sort keys %p
          ;
        my $msg = $parameters;
        $msg .= '<APP_TAB>' if $command eq 'log';
        $msg .= '<EOR>';
        my ( $ok, $response ) = writeINET( 'tcp', $host, $port, $msg );

        print $cgi->header(
            -type   => 'text/plain',
            -nph    => 1,
            -status => ( $ok ? 200 : 500 ),
        );
        print $response;
    }

    # http://localhost:8073/pst?QRA=FN32bt
    # http://localhost:8073/pst?AZIMUTH=180
    sub resp_pst {

# PstRotatorAz -- Software for Antenna Rotators User�s Manual Rev. 2.9 -- page 12
# <PST><AZIMUTH>85</AZIMUTH></PST> - set azimuth to 85 deg
# <PST><QRA>KN34BJ</QRA></PST> - send to program the locator (4/6/8 digits) and set the azimuth
# UDP port 12000
#   port + 1 for antenna position
#   <PST>AZ?</PST> - in answer to this command the program will report the antenna position to UDP Port + 1
#		PstRotatorAz reports the antenna position like this:
#		AZ:xxx<CR>
        my $cgi = shift;
        return if !ref $cgi;

        my $command    = ( split '/', $cgi->path_info )[-1];
        my @k          = grep { !/^__/ } $cgi->param;
        my %p          = $cgi->Vars;
        my $host       = delete $p{__host} || 'localhost';
        my $port       = delete $p{__port} || 12000;
        my $parameters = join '', map { MARKUPTAG( uc($_), $p{$_} ) } @k;
        my $msg        = MARKUPTAG( 'PST', $parameters ) . "\r\n";
        my ( $ok, $response ) = writeINET( 'udp', $host, $port, $msg );

        print $cgi->header(
            -type                        => 'text/plain',
            -nph                         => 1,
            -status                      => ( $ok ? 200 : 500 ),
            -Access_Control_Allow_Origin => '*',
        );
    }

#
#
#       d8888b.  .d88b.  d888888b  .o88b. d888888b db
#       88  `8D .8P  Y8. `~~88~~' d8P  Y8 `~~88~~' 88
#       88oobY' 88    88    88    8P         88    88
#       88`8b   88    88    88    8b         88    88
#       88 `88. `8b  d8'    88    Y8b  d8    88    88booo.
#       88   YD  `Y88P'     YP     `Y88P'    YP    Y88888P
#
#

    sub resp_rotctl {
        my $cgi = shift;
        return if !ref $cgi;

        my $command    = ( split '/', $cgi->path_info )[-1];
        my @k          = grep { !/^__/ } $cgi->param;
        my %p          = $cgi->Vars;
        my $host       = delete $p{__host} || 'localhost';
        my $port       = delete $p{__port} || 4535;
        my $parameters = join '', map { VALUETAG( $_, $p{$_} ) } @k;
        my $msg        = $command . " $parameters" . "\n";

        my ( $ok, $response ) = writeINET( 'tcp', $host, $port, $msg );

        if ( $command eq "P" && $parameters gt 0 ) {
            print $cgi->header(
                -type                        => 'text/plain',
                -nph                         => 1,
                -status                      => ( $ok ? 200 : 500 ),
                -Access_Control_Allow_Origin => '*',
            );
            print $response;
        }

        if ( $command eq "p" ) {
            print $cgi->header(
                -type                        => 'application/json',
                -nph                         => 1,
                -status                      => 200,
                -Access_Control_Allow_Origin => '*',
            );
            my $elevation = ( split '\n', $response )[-1];
            my $azimuth = ( split '\n', $response )[0];
            print qq!{"azimuth":"$azimuth","elevation":"$elevation"}!;
        }
    }

}    # package

print "ham-apps-proxy v$VER\n";
my $port = shift(@ARGV) || 8073;

# my $pid  = MyWebServer->new($port)->background();
my $pid = MyWebServer->new($port)->run();
