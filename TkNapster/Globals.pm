package MP3::TkNapster::Globals;

use strict;
use base 'Exporter';
use vars qw(@EXPORT
	    $nap $status $stats $uploads $downloads
	    $songwindow $sharedwindow $user_popup
	    $users $main
	    %Config
	   );

@EXPORT = qw(
	     $nap $status $stats $uploads $downloads
	     $songwindow $sharedwindow $user_popup
	     $users $main
	     %Config
	    );

$uploads = $downloads = 0;
$status = 'disconnected';
$stats  = 'none';

#$Config{download_dir} = './tmp';
#$Config{upload_dir}    = './songs';
$Config{download_dir} = '/home/lstein/projects/MP3-Napster/tmp';
$Config{upload_dir}    = '/home/lstein/projects/MP3-Napster/songs';

1;
