package MP3::Napster::MessageCodes;

use strict;
require Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);
$VERSION = '0.01';

@ISA = qw(Exporter MP3::Napster::Base);

@EXPORT = qw(
	%LINK                  INVALID_ENTITY         LOGIN_OPTIONS          SERVER_STATS
	%MESSAGES              INVALID_NICKNAME       MOTD                   SET_DATA_PORT
	ALREADY_REGISTERED     I_HAVE                 NEW_LOGIN              TIMEOUT
	BROWSE_REQUEST         JOIN_ACK               PART_CHANNEL           TRANSFER_ABORTED
	BROWSE_RESPONSE        JOIN_CHANNEL           PASSIVE_DOWNLOAD_REQ   TRANSFER_DONE
	BROWSE_RESPONSE_END    LINK_128K              PASSIVE_UPLOAD_REQ     TRANSFER_IN_PROGRESS
	CHANGE_DATA_PORT       LINK_14K               PASSIVE_UPLOAD_REQUEST TRANSFER_STARTED
	CHANGE_EMAIL           LINK_28K               PERMISSION_DENIED      TRANSFER_STATUS
	CHANGE_LINK_SPEED      LINK_33K               PING                   UPLOADING
	CHANGE_PASSWORD        LINK_56K               PONG                   UPLOAD_ACK
	CHANNEL_ENTRY          LINK_64K               PRIVATE_MESSAGE        UPLOAD_COMPLETE
	CHANNEL_MOTD           LINK_CABLE             PUBLIC_MESSAGE         UPLOAD_REQUEST
	CHANNEL_TOPIC          LINK_DSL               REGISTRATION_ACK       USER_COMMAND_DATA
	CHANNEL_USER_END       LINK_SPEED_REQUEST     REGISTRATION_REQUEST   USER_COMMENT
	CHANNEL_USER_ENTRY     LINK_SPEED_RESPONSE    REMOVE_ALL             USER_DEPARTS
	DATA_PORT_ERROR        LINK_T1                REMOVE_FILE            USER_JOINS
	DISCONNECTED           LINK_T3                RESUME_REQUEST         USER_LIST_ENTRY
	DOWNLOADING            LINK_UNKNOWN           RESUME_RESPONSE        USER_OFFLINE
	DOWNLOAD_ACK           LIST_CHANNELS          RESUME_RESPONSE_END    USER_SIGNOFF
	DOWNLOAD_COMPLETE      LIST_USERS             SEARCH                 USER_SIGNON
	DOWNLOAD_REQ           LOGIN                  SEARCH_RESPONSE        WHOIS_REQ
	ERROR                  LOGIN_ACK              SEARCH_RESPONSE_END    WHOIS_RESPONSE
	GET_ERROR              LOGIN_ERROR            SEND_PUBLIC_MESSAGE    WHOWAS_RESPONSE
);

use MP3::Napster::Base ('LINK' => {
				   LINK_UNKNOWN => 0,
				   LINK_14K     => 1,
				   LINK_28K     => 2,
				   LINK_33K     => 3,
				   LINK_56K     => 4,
				   LINK_64K     => 5,
				   LINK_128K    => 6,
				   LINK_CABLE   => 7,
				   LINK_DSL     => 8,
				   LINK_T1      => 9,
				   LINK_T3      => 10},
			'MESSAGES' => {
				       ERROR                => 0,
				       LOGIN                => 2,
				       LOGIN_ACK            => 3,
				       NEW_LOGIN            => 6,
				       REGISTRATION_REQUEST => 7,
				       REGISTRATION_ACK     => 8,
				       ALREADY_REGISTERED   => 9,
				       INVALID_NICKNAME     => 10,
				       PERMISSION_DENIED    => 11,
				       LOGIN_ERROR          => 13,
				       LOGIN_OPTIONS        => 14,
				       I_HAVE               => 100,
				       REMOVE_FILE          => 102,
				       REMOVE_ALL           => 110,
				       SEARCH               => 200,
				       SEARCH_RESPONSE      => 201,
				       SEARCH_RESPONSE_END  => 202,
				       DOWNLOAD_REQ         => 203,
				       DOWNLOAD_ACK         => 204,
				       PRIVATE_MESSAGE      => 205,
				       GET_ERROR            => 206,
				       USER_SIGNON          => 209,
				       USER_SIGNOFF         => 210,
				       BROWSE_REQUEST       => 211,
				       BROWSE_RESPONSE      => 212,
				       BROWSE_RESPONSE_END  => 213,
				       SERVER_STATS         => 214,
				       RESUME_REQUEST       => 215,
				       RESUME_RESPONSE      => 216,
				       RESUME_RESPONSE_END  => 217,
				       DOWNLOADING          => 218,
				       DOWNLOAD_COMPLETE    => 219,
				       UPLOADING            => 220,
				       UPLOAD_COMPLETE      => 221,
				       JOIN_CHANNEL         => 400,
				       PART_CHANNEL         => 401,
				       SEND_PUBLIC_MESSAGE  => 402,
				       PUBLIC_MESSAGE       => 403,
				       INVALID_ENTITY       => 404,
				       JOIN_ACK             => 405,
				       USER_JOINS           => 406,
				       USER_DEPARTS         => 407,
				       CHANNEL_USER_ENTRY   => 408,
				       CHANNEL_USER_END     => 409,
				       CHANNEL_TOPIC        => 410,
				       CHANNEL_MOTD         => 425,
				       PASSIVE_DOWNLOAD_REQ => 500,
				       UPLOAD_REQUEST       => 501,
				       LINK_SPEED_REQUEST   => 600,
				       LINK_SPEED_RESPONSE  => 601,
				       WHOIS_REQ            => 603,
				       WHOIS_RESPONSE       => 604,
				       WHOWAS_RESPONSE      => 605,
				       PASSIVE_UPLOAD_REQUEST => 607,
				       UPLOAD_ACK           => 608,
				       SET_DATA_PORT        => 613,
				       LIST_CHANNELS        => 617, # used both to start and end channel list
				       CHANNEL_ENTRY        => 618,
				       USER_OFFLINE         => 620,
				       MOTD                 => 621,
				       DATA_PORT_ERROR      => 626,
				       CHANGE_LINK_SPEED    => 700,
				       CHANGE_PASSWORD      => 701,
				       CHANGE_EMAIL         => 702,
				       CHANGE_DATA_PORT     => 703,
				       PING                 => 751,
				       PONG                 => 752,
				       USER_EMOTE           => 824,
				       USER_LIST_ENTRY      => 825,
				       LIST_USERS           => 830, # used both to start and end user list

				       # pseudo events
				       TRANSFER_STARTED     => 2000,
				       TRANSFER_DONE        => 2001,
				       TRANSFER_IN_PROGRESS => 2002,
				       TRANSFER_ABORTED     => 2003,
				       TRANSFER_STATUS      => 2004,
				       DISCONNECTED         => 2005,
				       USER_COMMAND_DATA    => 2006, # data ready on STDIN

				       TIMEOUT              => 9999,
				      }
		       );

1;
