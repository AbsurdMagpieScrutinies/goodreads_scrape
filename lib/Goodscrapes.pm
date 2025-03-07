package Goodscrapes;
use strict;
use warnings;
use 5.18.0;
use utf8;


###############################################################################

=pod

=encoding utf8

=head1 NAME

Goodscrapes - Goodreads.com HTML API


=head1 VERSION

=over

=item * Updated: 2019-08-27

=item * Since: 2014-11-05

=back

=cut

our $VERSION = '1.54';  # X.XX version format required by Perl


=head1 COMPARED TO THE OFFICIAL API

=over

=item * focuses on analysing, not updating info on GR

=item * less limited, e.g., reading shelves and reviews of other members:
        Goodscrapes can scrape thousands of fulltext reviews.

=item * official is slow too; API users are even second-class citizen

=item * theoretically this library is more likely to break, 
        but Goodreads progresses very very slowly: nothing
        actually broke between 2019-2014 (I started this);
        actually their API seems to change more often than
        their web pages; they can and do disable API functions 
        without being noticed by the majority, but they cannot
        easily disable important webpages that we use too;
        There are unit-tests to detect markup changes on the
        scraped Goodreads.com website.

=item * this library grew with every new usecase and program;
        it retries operations on errors on Goodreads.com,
        which are not seldom (over capacity, exceptions etc);
        it saw a lot of flawed data such as wrong review dates 
        ("Jan 01, 1010"), which broke Time::Piece.

=item * Goodreads "isn't eating its own dog food"
        https://www.goodreads.com/topic/show/18536888-is-the-public-api-maintained-at-all#comment_number_1

=back


=head1 LIMITATIONS

=over

=item * slow: version with concurrent AnyEvent::HTTP requests was marginally 
        faster, so I sticked with simpler code; doesn't actually matter
        due to Amazon's and Goodreads' request throttling. You can only
        speed things up significantly with a pool of work-sharing computers 
        and unique IP addresses...

=item * just text pattern matching, no ECMAScript execution and DOM parsing
        (so far sufficient and faster)

=back


=head1 HOW TO USE

=over

=item * for real-world usage examples see Andre's Goodreads Toolbox

=item * C<_> prefix means I<private> function or constant (use in module only)

=item * C<ra> prefix means array reference, C<rh> prefix means hash reference

=item * C<on> prefix or C<fn> suffix means function variable

=item * constants are uppercase, functions lowercase
	   
=item * Goodscrapes code in your program is usually recognizable by the
        'g' or 'GOOD' prefix in the function or constant name

=item * common internal abbreviations: 
        pfn = progress function, bfn = book handler function, 
        pag = page number, nam = name, au = author, bk = book, uid = user id,
        bid = book id, aid = author id, rat = rating, tit = title, 
        q   = query string, slf = shelf name, shv = shelves names, 
        t0  = start time of an operation, ret = return code, 
        tmp = temporary helper variable, gp = group, gid = group id,
	   us  = user

=back


=head1 AUTHOR

https://github.com/andre-st/


=cut

###############################################################################


use base 'Exporter';
our @EXPORT = qw( 
	$GOOD_ERRMSG_NOBOOKS
	$GOOD_ERRMSG_NOMEMBERS
	
	gverifyuser
	gverifyshelf
	gisbaduser
	gmeter
	glogin
	gsetcache
	
	gsearch
	greadbook
	greaduser
	greadusergp
	greadshelf
	greadauthors
	greadauthorbk
	greadsimilaraut
	greadreviews
	greadfolls 
	gsocialnet
	
	amz_book_html
	ghtmlhead
	ghtmlfoot
	);


# Perl core:
use Time::Piece;
use Carp             qw( croak );
use List::Util       qw( sum );
# Third party:
use List::MoreUtils  qw( any );
use Cache::Cache     qw( $EXPIRES_NEVER $EXPIRES_NOW );
use Cache::FileCache;
use IO::Prompter;
use URI::Escape;
use HTML::Entities;
use WWW::Curl::Easy;


# Non-module message strings to be used in programs:
our $GOOD_ERRMSG_NOBOOKS   = "[FATAL] No books found. Check the privacy settings at Goodreads.com and ensure access by 'anyone (including search engines)'.";
our $GOOD_ERRMSG_NOMEMBERS = '[FATAL] No members found. Check cookie and try empty /tmp/FileCache/';


# Module error codes:
#   Severity levels:  0 < WARN < ERROR < CRITICAL < FATAL
#   Adding a severity level influences coping strategy
our $_ENO_WARN        = 300;  # ignore and continue
our $_ENO_GR400       = $_ENO_WARN  + 1;
our $_ENO_GR404       = $_ENO_WARN  + 2;
our $_ENO_GRSIGNIN    = $_ENO_WARN  + 3;
our $_ENO_ERROR       = 400;  # retry n times and continue
our $_ENO_GRUNAVAIL   = $_ENO_ERROR + 1;
our $_ENO_GRUNEXPECT  = $_ENO_ERROR + 2;
our $_ENO_CRIT        = 500;  # retry until user CTRL-C
our $_ENO_GRCAPACITY  = $_ENO_CRIT  + 1;
our $_ENO_GRMAINTNC   = $_ENO_CRIT  + 2;
our $_ENO_CURL        = $_ENO_CRIT  + 3;
our $_ENO_NOHTML      = $_ENO_CRIT  + 4;
our $_ENO_FATAL       = 600;  # abort
our $_ENO_NODICT      = $_ENO_FATAL + 1;
our $_ENO_BADSHELF    = $_ENO_FATAL + 2;
our $_ENO_BADUSER     = $_ENO_FATAL + 3;
our $_ENO_BADARG      = $_ENO_FATAL + 4;
our $_ENO_BADLOGIN    = $_ENO_FATAL + 5;

our $_MAXRETRIES      = 5;     # 
our $_RETRYDELAY_SECS = 60*3;  # Total retry time: 15 minutes


# Misc module message strings:
our $_MSG_RETRYING_FOREVER = "[NOTE ] Retrying in 3 minutes... Press CTRL-C to exit (pid=$$)\n";
our $_MSG_RETRYING_NTIMES  = "[NOTE ] Retrying in 3 minutes (%d times before skipping this one)... Press CTRL-C to exit (pid=$$)\n";  # retriesleft

our %_ERRMSG = 
(
	# _ENO_GRxxx are messages from the Goodreads.com website:
	$_ENO_WARN       => "\n[WARN ] %s",               # url
	$_ENO_GR400      => "\n[WARN ] Bad request: %s",  # url
	$_ENO_GR404      => "\n[WARN ] Not found: %s",    # url
	$_ENO_GRSIGNIN   => "\n[WARN ] Sign-in for %s => Cookie invalid or not set: see glogin()", # url
	$_ENO_ERROR      => "\n[ERROR] %s",               # url
	$_ENO_GRUNAVAIL  => "\n[ERROR] Goodreads.com \"temporarily unavailable\".",
	$_ENO_GRUNEXPECT => "\n[ERROR] Goodreads.com encountered an \"unexpected error\": %s",  #url
	$_ENO_GRCAPACITY => "\n[CRIT ] Goodreads.com is over capacity.",
	$_ENO_GRMAINTNC  => "\n[CRIT ] Goodreads.com is down for maintenance.",
	$_ENO_CURL       => "\n[CRIT ] %s - %s %s",       # url, err, errbuf
	$_ENO_NOHTML     => "\n[CRIT ] No HTML body: %s", # url
	$_ENO_FATAL      => "\n[FATAL] %s",               # url
	$_ENO_NODICT     => "\n[FATAL] Cannot open dictionary file: %s",       # path
	$_ENO_BADSHELF   => "\n[FATAL] Invalid Goodreads shelf name \"%s\". Look at your shelf URLs.",  # name
	$_ENO_BADUSER    => "\n[FATAL] Invalid Goodreads user ID \"%s\".",  # id
	$_ENO_BADARG     => "\n[FATAL] Argument \"%s\" expected.",             # name
	$_ENO_BADLOGIN   => "\n[FATAL] Incorrect login."
);
sub _errmsg { no warnings 'redundant'; my $eno = shift; return sprintf( $_ERRMSG{$eno}, @_ ); }


# Misc module constants:
#our $_USERAGENT     = 'Googlebot/2.1 (+http://www.google.com/bot.html)';
our $_USERAGENT     = 'Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US; rv:1.8.1.13) Gecko/20080311 Firefox/2.0.0.13';
our $_NOBOOKIMGURL  = 'https://s.gr-assets.com/assets/nophoto/book/50x75-a91bf249278a81aabab721ef782c4a74.png';
our $_NOUSERIMGURL  = 'https://s.gr-assets.com/assets/nophoto/user/u_50x66-632230dc9882b4352d753eedf9396530.png';
our $_NOGROUPIMGURL = 'https://s.gr-assets.com/assets/nophoto/group/50x66-14672b6c5b97a4836a13efdb6a1958d2.jpg';
our $_ANYPRIVATEURL = 'https://www.goodreads.com/friend';
our $_SIGNINURL     = 'https://www.goodreads.com/user/sign_in';
our $_HOMEURL       = 'https://www.goodreads.com';
our $_SORTNEW       = 'newest';
our $_SORTOLD       = 'oldest';
our $_EARLIEST      = Time::Piece->strptime( '1970-01-01', '%Y-%m-%d' );
our @_BADPROFILES   =     # TODO external config file
(
	'1000834',  #  3.000 books   "NOT A BOOK" author
	'5158478'   # 10.000 books   "Anonymous"  author
);

our $_cookie    = undef;
our $_cache_age = $EXPIRES_NOW;  # see gsetcache()
our $_cache     = new Cache::FileCache({ namespace => 'Goodscrapes' });



=head1 DATA STRUCTURES

=head2 Note

=over

=item * never cast 'id' to int or use %d format string, despite digits only, 
        compare as strings

=item * don't expect all attributes set (C<undef>), 
        this depends on the available info on the scraped page

=back



=head2 %book

=over

=item * id              =E<gt> C<string>

=item * title           =E<gt> C<string>

=item * isbn            =E<gt> C<string>

=item * isbn13          =E<gt> C<string>

=item * num_pages       =E<gt> C<int>

=item * num_reviews     =E<gt> C<int>

=item * num_ratings     =E<gt> C<int>    103 for example

=item * avg_rating      =E<gt> C<float>  4.36 for example

=item * stars           =E<gt> C<int>    rounded avg_rating, e.g., 4

=item * format          =E<gt> C<string> (binding)

=item * user_rating     =E<gt> C<int>    number of stars 1,2,3,4 or 5

=item * user_read_count =E<gt> C<int>

=item * user_num_owned  =E<gt> C<int>

=item * user_date_read  =E<gt> C<Time::Piece>

=item * user_date_added =E<gt> C<Time::Piece>

=item * ra_user_shelves =E<gt> C<string[]> reference

=item * url             =E<gt> C<string>

=item * img_url         =E<gt> C<string>

=item * review_id       =E<gt> C<string>

=item * year            =E<gt> C<int>     (original publishing date)

=item * year_edit       =E<gt> C<int>     (edition publishing date)

=item * rh_author       =E<gt> C<L<%user|"%user">> reference

=back



=head2 %user

=over

=item * id          =E<gt> C<string>

=item * name        =E<gt> C<string>  "Firstname Lastname"

=item * name_lf     =E<gt> C<string>  "Lastname, Firstname"

=item * residence   =E<gt> C<string>  (might require login)

=item * age         =E<gt> C<int>     (might require login)

=item * num_books   =E<gt> C<int>

=item * is_friend   =E<gt> C<bool>

=item * is_author   =E<gt> C<bool>

=item * is_female   =E<gt> C<bool>

=item * is_private  =E<gt> C<bool>

=item * is_staff    =E<gt> C<bool>, is a Goodreads.com employee

=item * url         =E<gt> C<string> URL to the user's profile page

=item * works_url   =E<gt> C<string> URL to the author's distinct works (is_author == 1)

=item * img_url     =E<gt> C<string>

=item * _seen       =E<gt> C<int>    incremented if user already exists in a load-target structure

=back



=head2 %review

=over

=item * id          =E<gt> C<string>

=item * rh_user     =E<gt> C<L<%user|"%user">> reference

=item * book_id     =E<gt> C<string>

=item * rating      =E<gt> C<int> 
                       with 0 meaning no rating, "added" or "marked it as abandoned" 
                       or something similar

=item * rating_str  =E<gt> C<string> 
                       represention of rating, e.g., 3/5 as S<"[***  ]"> or S<"[TTT  ]"> 
                       if there's additional text, or S<"[ttt  ]"> if not longer than 160 chars

=item * text        =E<gt> C<string>

=item * date        =E<gt> C<Time::Piece>

=item * url         =E<gt> C<string>  full text review

=back



=head2 %group

=over

=item * id          =E<gt> C<string>

=item * name        =E<gt> C<string>

=item * url         =E<gt> C<string>

=item * img_url     =E<gt> C<string>

=item * num_members =E<gt> int

=back


=cut



=head1 PUBLIC ROUTINES



=head2 C<string> gverifyuser( I<$user_id_to_verify> )

=over

=item * returns a sanitized, valid Goodreads user id or kills 
        the current process with an error message

=back

=cut

sub gverifyuser
{
	my $uid = shift // '';
	
	return $1 if $uid =~ /(\d+)/ 
		or croak( _errmsg( $_ENO_BADUSER, $uid ));
}




=head2 C<string> gverifyshelf( I<$name_to_verify> )

=over

=item * returns the given shelf name if valid 

=item * returns a shelf which includes all books if no name given

=item * kills the current process with an error message if name is malformed

=back

=cut

sub gverifyshelf
{
	my $nam = shift // ''; # '%23ALL%23';
	
	croak( _errmsg( $_ENO_BADSHELF, $nam ))
 		if length $nam == 0 || $nam =~ /[^%a-zA-Z0-9_\-,]/;
		
	return $nam;
}




=head2 C<bool> gisbaduser( I<$user_or_author_id> )

=over

=item * returns true if the given user or author is blacklisted 
        and would slow down any analysis

=back

=cut

sub gisbaduser
{
	my $uid = shift or return 1;
	return any{ $_ eq $uid } @_BADPROFILES;
}




=head2 C<sub> gmeter( I<$unit_str = ''> )

=over

=item * generates and returns a CLI progress indicator function $f, 
        with I<$f-E<gt>( 20 )> adding 20 to the last values and 
        printing the sum like "40 unit_str".
        Given a second (max value) argument I<$f-E<gt>( 10, 100 )>, 
        it will print a percentage without any unit: "10%".
        Given a modern terminal, the text remains at the same 
        position if the progress function is called multiple times.

=back

=cut

sub gmeter
{
	my $unit = shift // '';
	return sub{
		state $is_first = 1;
		state $v        = 0;
		
		my $f  = defined $_[1]  ?  "%3d%%"                      :  "%5s $unit";
		   $v += defined $_[1]  ?  $_[1] ? $_[0]/$_[1]*100 : 0  :  ($_[0] || 0);  # 2nd ? avoids div by zero
		   $v  = 100 if defined $_[1] && $v > 100;  # Allows to trigger "100%" by passing (1, 1)
		my $s  = sprintf( $f, $v );
		
		my $ansicodeslen = sum( map( length, $s =~ /\x1b\[[0-9;]*m/g ) ) || 0;
		
		print "\b" x (length( $s )-$ansicodeslen) if !$is_first;     # Backspaces prev meter if any (same-width format str)
		print $s;
		$is_first = 0;
	};
}




=head2 C<void> glogin(I<{ ... }>)

=over

=item * some Goodreads.com pages are only accessible by authenticated members

=item * C<usermail =E<gt> string>

=item * C<userpass =E<gt> string> 

=item * C<r_userid =E<gt> string ref> set user ID if variable is empty/undef [optional]

=back

=cut

sub glogin
{
	my (%args) = @_;
	my $mail   =_require_arg( 'usermail', $args{ usermail });
	my $pass   = $args{ userpass } // undef;
	my $ruid   = $args{ r_userid } // undef;
	
	# Some people don't want their password on the command line 
	# as it shows up in the command history, process list etc.
	# 
	$pass = prompt( -prompt => "Enter GR password for $mail:", 
	                -echo   => '*',
	                -return => "\nSigning in to Goodreads... ",
	                -out    => *STDOUT,
	                -in     => *STDIN ) while !$pass;
	
	# Scrape current security tokens:
	my $htm   = _html( $_SIGNINURL, $_ENO_ERROR, 0 );
	my $tok   = $htm =~ /name="authenticity_token" value="([^"]+)/ ? $1 : undef;
	my $nonce = $htm =~ /name='n' type='hidden' value='([^']+)/    ? $1 : undef;
	
	# Send login form:
	my $formdata = 'sign_in=1'
	             . "&n=${nonce}"
	             . '&authenticity_token=' . uri_escape( $tok  )
	             . '&user%5Bemail%5D='    . uri_escape( $mail )
	             . '&user%5Bpassword%5D=' . uri_escape( $pass )
	             . '&remember_me=on'
	             . '&next=Sign+in';
	
	my $curl = WWW::Curl::Easy->new;
	_setcurlopts( $curl );
	$curl->setopt( $curl->CURLOPT_URL,        $_SIGNINURL );
	$curl->setopt( $curl->CURLOPT_POST,       1           );
	$curl->setopt( $curl->CURLOPT_POSTFIELDS, $formdata   );
	$curl->setopt( $curl->CURLOPT_WRITEDATA,  \$htm       );
	$curl->perform();   # Saves login data to $_cookie (set by _setcurlopts)
	
	# Don't leave password in memory:
	# This f'ups $curl->perform() although noted afterwards, concurrent?
	#$pass     = '#' x length( $pass     );
	#$formdata = '#' x length( $formdata );
	
	# Get user ID if needed:
	if( defined $ruid && !$$ruid )
	{
		$htm   = _html( $_HOMEURL, $_ENO_ERROR, 0 );       # Also POST 302 target
		$$ruid = $htm =~ /index_rss\/(\d+)/ ? $1 : undef;
		
		print( "OK!\n" ) if $$ruid && !$args{ userpass };  # Only if prompt before
		croak( _errmsg( $_ENO_BADLOGIN )) unless $$ruid;
	}
}




=head2 C<void> gsetcache( I<$number, $unit = 'days'> )

=over

=item * scraping Goodreads.com is a very slow process

=item * scraped documents can be cached if you don't need them "fresh"
        during development time
        or long running sessions (cheap recovery on crash, power blackout or pauses),
	   or when experimenting with parameters

=item * unit can be C<"minutes">, C<"hours">, C<"days">

=back

=cut

sub gsetcache
{
	my $num     = shift // 0;
	my $unit    = shift // 'days';
	$_cache_age = "${num} ${unit}";
}




=head2 C<L<%book|"%book">> greadbook( $book_id )

=cut

sub greadbook
{
	my $bid = _require_arg( 'book_id', shift );
	return _extract_book( _html( _book_url( $bid )));
}




=head2 C<L<%user|"%user">> greaduser( $user_id, $prefer_author = 0 )

=over

=item * there can be a different user and author with the same ID 
        (2456: Joana vs Chuck Palahniuk); 
        if there's no user but an author, Goodreads would redirect 
        to the author page with the same ID and this function
        would return the author

=item * if ambiguous you can set the I<$prefer_author> flag

=back

=cut

sub greaduser
{
	my $uid  = gverifyuser( shift );
	my $isau = shift // 0;
	my $htm  = _html( _user_url( $uid, $isau ));
	return $isau ? _extract_author( $htm ) : _extract_user( $htm );
}



=head2 C<void> greadusergp(I<{ ... }>)

=over

=item * reads all group memberships of the given user into I<rh_into>

=item * C<from_user_id =E<gt> string>

=item * C<rh_into      =E<gt> hash reference (id =E<gt> L<%group|"%group">,...)>

=item * C<on_group     =E<gt> sub( L<%group|"%group"> )> [optional]

=item * C<on_progress  =E<gt> sub> see C<gmeter()> [optional]

=back

=cut

sub greadusergp
{
	my (%args) = @_;
	my $uid    = gverifyuser( $args{ from_user_id });
	my $rh     =_require_arg( 'rh_into', $args{ rh_into });
	my $gfn    = $args{ on_group    }  // sub{};
	my $pfn    = $args{ on_progress }  // sub{};
	my $pag    = 1;
	
	# Just one page:
	while( _extract_user_groups( $rh, $gfn, $pfn, _html( _user_groups_url( $uid, $pag++ )))) {};
}




=head2 C<void> greadshelf(I<{ ... }>)

=over

=item * reads a list of books present in the given shelves of the given user

=item * C<from_user_id    =E<gt> string>

=item * C<ra_from_shelves =E<gt> string-array reference> with shelf names

=item * C<rh_into         =E<gt> hash reference (id =E<gt> L<%book|"%book">,...)> [optional]

=item * C<on_book         =E<gt> sub( L<%book|"%book"> )> [optional]

=item * C<on_progress     =E<gt> sub> see C<gmeter()> [optional]

=back

=cut

sub greadshelf
{
	my (%args) = @_;
	my $uid    = gverifyuser( $args{ from_user_id });
	my $ra_shv =_require_arg( 'ra_from_shelves', $args{ ra_from_shelves });
	my $rh     = $args{ rh_into     }  // undef;
	my $bfn    = $args{ on_book     }  // sub{};
	my $pfn    = $args{ on_progress }  // sub{};
	my %books; # Using pre-populated $rh would confuse progess counters
	
	gverifyshelf( $_ ) foreach (@$ra_shv);
	
	for my $s (@$ra_shv)
	{
		my $pag = 1;
		while( _extract_books( \%books, $bfn, $pfn, _html( _shelf_url( $uid, $s, $pag++ )))) {}
	}
	
	%$rh = ( %$rh, %books ) if $rh;  # Merge
}




=head2 C<void> greadauthors(I<{ ... }>)

=over

=item * gets a list of authors whose books are present in the given shelves of the given user

=item * C<from_user_id    =E<gt> string>

=item * C<ra_from_shelves =E<gt> string-array reference> with shelf names

=item * C<rh_into         =E<gt> hash reference (id =E<gt> L<%user|"%user">,...)> [optional]

=item * C<on_progress     =E<gt> sub> see C<gmeter()> [optional]

=item * If you need authors I<and> books data, then use C<greadshelf>
        which also populates the I<author> property of every book

=item * skips authors where C<gisbaduser()> is true

=back

=cut

sub greadauthors
{
	my (%args) = @_;
	my $rh     = $args{ rh_into     }  // undef;
	my $pfn    = $args{ on_progress }  // sub{};
	my %auts;  # Using pre-populated $rh would confuse progress counters
	
	my $pickauthorsfn = sub
	{
		my $aid = $_[0]->{rh_author}->{id};
		return if gisbaduser( $aid );
		$pfn->( 1 ) if !exists $auts{$aid};  # Don't count duplicates (multiple shelves)
		$auts{$aid} = $_[0]->{rh_author};
	};
	
	greadshelf( from_user_id    => $args{ from_user_id    },
	            ra_from_shelves => $args{ ra_from_shelves },
	            on_book         => $pickauthorsfn );
	
	%$rh = ( %$rh, %auts ) if $rh;  # Merge
}




=head2 C<void> greadauthorbk(I<{ ... }>)

=over

=item * reads the Goodreads.com list of books written by the given author

=item * C<author_id   =E<gt> string>

=item * C<limit       =E<gt> int> number of books to read into C<rh_into>

=item * C<rh_into     =E<gt> hash reference (id =E<gt> L<%book|"%book">,...)>

=item * C<on_book     =E<gt> sub( L<%book|"%book"> )> [optional]

=item * C<on_progress =E<gt> sub> see C<gmeter()> [optional]

=back

=cut

sub greadauthorbk
{
	my (%args) = @_;	
	my $rh     =_require_arg( 'rh_into', $args{ rh_into });
	my $aid    = gverifyuser( $args{ author_id });
	my $limit  = $args{ limit       }  // 999999999;
	my $bfn    = $args{ on_book     }  // sub{};
	my $pfn    = $args{ on_progress }  // sub{};
	my $pag    = 1;
	
	while( _extract_author_books( $rh, \$limit, $bfn, $pfn, _html( _author_books_url( $aid, $pag++ )))) {};
}




=head2 C<void> greadreviews(I<{ ... }>)

=over

=item * loads ratings (no text), reviews (text), "to-read", "added" etc;
        you can filter later or via I<on_filter> parameter

=item * C<rh_for_book =E<gt> hash reference L<%book|"%book">>, see C<greadbook()>

=item * C<rh_into     =E<gt> hash reference (id =E<gt> L<%review|"%review">,...)>

=item * C<since       =E<gt> Time::Piece> [optional]

=item * C<on_filter   =E<gt> sub( L<%review|"%review"> )>, return 0 to drop [optional]

=item * C<on_progress =E<gt> sub> see C<gmeter()> [optional]

=item * C<dict_path   =E<gt> string> path to a dictionary file (1 word per line) [optional]

=item * C<text_only   =E<gt> bool> overwrites C<on_filter> argument [optional, default 0 ]

=item * C<rigor       =E<gt> int> [optional, default 2]

  level 0   = search newest reviews only (max 300 ratings)
  level 1   = search with a combination of filters (max 5400 ratings)
  level 2   = like 1 plus dict-search if more than 3000 ratings with stall-time of 2 minutes
  level n   = like 1 plus dict-search with stall-time of n minutes

=back

=cut

sub greadreviews
{
	my (%args)   = @_;
	my $rh_book  =_require_arg( 'rh_for_book', $args{ rh_for_book });
	my $rigor    = $args{ rigor       }  // 2;
	my $dictpath = $args{ dict_path   }  // undef;
	my $rh       = $args{ rh_into     }  // undef;
	my $istxt    = $args{ text_only   }  // 0;
	my $pfn      = $args{ on_progress }  // sub{};
	my $since    = $args{ since       }  // $_EARLIEST;
	   $since    = Time::Piece->strptime( $since->ymd, '%Y-%m-%d' );  # Nullified time in GR too
	my $limit    = $istxt ? ( $rh_book->{num_reviews}  // 5000000 ) 
	                      : ( $rh_book->{num_ratings}  // 5000000 );
	my $ffn      = $istxt ? ( sub{ $_[0]->{text} } )
	                      : ( $args{ on_filter }  // sub{ return 1 } );
	my $bid      = $rh_book->{id};
	my %revs;    # Unique and empty, otherwise we cannot easily compute limits
	
	
	# Allow user to interrupt search with CTRL-C:
	my $gotsigint   = 0;
	#local $SIG{INT} = sub{ $gotsigint = 1; };  	
	
	
	# Goodreads reviews filters get us dissimilar(!) subsets which are merged
	# here: Don't assume that these filters just load a _subset_ of what you
	# see if _no filters_ are applied. Given enough ratings and reviews, each
	# filter finds reviews not included in any other subset.  Theoretical
	# limit here is 5400 reviews: 6*3 filter combinations * max. 300 displayed 
	# reviews (Goodreads limit).
	# 
	my @rateargs = $rigor == 0 ? ( undef     ) : ( undef, 1..5                 );
	my @sortargs = $rigor == 0 ? ( $_SORTNEW ) : ( undef, $_SORTNEW, $_SORTOLD );
	for my $r (@rateargs)
	{
		for my $s (@sortargs)
		{
			my $pag = 1;
			while( _extract_revs( \%revs, $pfn, $ffn, $since, _html( _revs_url( $bid, $s, $r, undef, $pag++ )))) {};
			
			# "to-read", "added" have to be loaded before the rated/reviews
			# (undef in both argument-lists first) - otherwise we finish
			# too early since $limit equals the number of *ratings* only.
			# Ugly code but correct in theory:
			# 
			my $numrated = scalar( grep{ defined $_->{rating} } values %revs ); 
			goto DONE if $numrated >= $limit || $gotsigint;
		}
	}
	

	# Dict-search works well with many ratings but sometimes poorly with few.
	# Woolf's "To the Lighthouse" has 5514 text reviews: 948 found without 
	# dict-search, with dict-search: 3057 (ngrams) or 4962 (words).
	# If searching and searching and nothing happens after $stalltime seconds
	# then we abort this method.
	# 
	goto DONE if $rigor <  2;
	goto DONE if $rigor == 2 && $limit < 3000;
	
 	my $stalltime = $rigor * 60;  
	my $t0        = time;  # Stuff above might already take 60s
	
	open( my $fh, '<', $dictpath ) or croak( _errmsg( $_ENO_NODICT, $dictpath ));
	chomp( my @dict = <$fh> );
	close $fh;
	
	for my $word (@dict)
	{
		goto DONE if time-$t0 > $stalltime 
				|| scalar keys %revs >= $limit 
				|| $gotsigint;
		
		my $numbefore = scalar keys %revs;
		
		_extract_revs( \%revs, $pfn, $ffn, $since, _html( _revs_url( $bid, undef, undef, $word )));
		
		$t0 = time if scalar keys %revs > $numbefore;  # Resets stall-timer
	}
	
DONE:
	
	%$rh = ( %$rh, %revs ) if $rh;  # Merge
}




=head2 C<void> greadfolls(I<{ ... }>)

=over

=item * queries Goodreads.com for the friends and followees list of the given user

=item * C<rh_into            =E<gt> hash reference (id =E<gt> L<%user|"%user">,...)>

=item * C<from_user_id       =E<gt> string>

=item * C<on_user            =E<gt> sub( %user )> return false to exclude user from $rh_into [optional]

=item * C<on_progress        =E<gt> sub> see C<gmeter()> [optional]

=item * C<discard_threshold> =E<gt> number> don't add anything to $rh_into if number of folls exceeds limit [optional];
                                    use this to drop degenerated accounts which would just add noise to the data

=item * C<incl_authors       =E<gt> bool> [optional, default 1]

=item * C<incl_friends       =E<gt> bool> [optional, default 1]

=item * C<incl_followees     =E<gt> bool> [optional, default 1]

=item * Precondition: glogin()

=back

=cut

sub greadfolls
{
	my (%args)  = @_;
	my $rh      =_require_arg( 'rh_into', $args{ rh_into });
	my $uid     = gverifyuser( $args{ from_user_id });
	my $isaut   = $args{ incl_authors      } // 1;
	my $isfrn   = $args{ incl_friends      } // 1;
	my $isfol   = $args{ incl_followees    } // 1;
	my $dishold = $args{ discard_threshold } // 9999999;
	my $ufn     = $args{ on_user           } // sub{ 1 };   # TODO
	my $pfn     = $args{ on_progress       } // sub{   };   # TODO
	my $pag;
	
	if( $isfol )
	{
		$pag = 1; 
		while( _extract_followees( $rh, $pfn, $isaut, $dishold, _html( _followees_url( $uid, $pag++ )))) {};
	}
	
	if( $isfrn )
	{
		$pag = 1; 
		while( _extract_friends( $rh, $pfn, $isaut, $dishold, _html( _friends_url( $uid, $pag++ )))) {};
	}
	
}




=head2 C<void> gsocialnet(I<{ ... }>)

=over

=item * C<from_user_id    =E<gt> string>

=item * C<rh_into_nodes   =E<gt> hash reference (id =E<gt> L<%user|"%user">,...)>

=item * C<ra_into_edges   =E<gt> array reference ({from =E<gt> id, to =E<gt> id},...)>

=item * C<ignore_nhood_gt =E<gt> int> ignore users with with a neighbourhood > N [optional, default 1000];
                                      such users just add noise to the data and waste computing time

=item * C<depth           =E<gt> int>  [optional, default 1]

=item * C<incl_authors    =E<gt> bool> [optional, default 0]

=item * C<incl_friends    =E<gt> bool> [optional, default 1]

=item * C<incl_followees  =E<gt> bool> [optional, default 1]

=item * C<on_progress     =E<gt> sub({ done =E<gt> int, count =E<gt> int, perc =E<gt> int, depth =E<gt> int })>  [optional]

=item * C<on_user         =E<gt> sub( %user )> return false to exclude user [optional]

=item * Precondition: glogin()

=back

=cut

sub gsocialnet
{
	my (%args) = @_;
	my $uid    =_require_arg( 'from_user_id',  $args{ from_user_id  });
	my $rh_n   =_require_arg( 'rh_into_nodes', $args{ rh_into_nodes });
	my $ra_e   =_require_arg( 'ra_into_edges', $args{ ra_into_edges });
	
	$args{ depth           } //= 2;
	$args{ on_user         } //= sub{ 1 };
	$args{ on_progress     } //= sub{   };
	$args{ ignore_nhood_gt } //= 1000;
	$args{ incl_friends    } //= 1;
	$args{ incl_followees  } //= 1;
	$args{ incl_authors    } //= 0;
	
	return if $args{ depth } == 0;               # Stop recursion or if nonsense arg
	return if any{ $_->{from} eq $uid } @$ra_e;  # Avoid loops
	
	my %nhood;
	greadfolls( rh_into           => \%nhood,
	            from_user_id      => $args{ from_user_id    },
	            on_user           => $args{ on_user         },
	            discard_threshold => $args{ ignore_nhood_gt },
	            incl_authors      => $args{ incl_authors    },
	            incl_followees    => $args{ incl_followees  },
	            incl_friends      => $args{ incl_friends    });
	
	   %$rh_n       = ( %$rh_n, %nhood );
	my $nhood_count = scalar( keys %nhood );
	my $nhood_done  = 0;
	
	for my $nhood_uid (keys %nhood)
	{
		$args{ on_progress }->( done    =>   $nhood_done,
		                        count   =>   $nhood_count,
		                        perc    => ++$nhood_done / $nhood_count * 100,
		                        depth   =>   $args{depth},
		                        from_id =>   $uid,
		                        to_id   =>   $nhood_uid );
		
		push( @$ra_e, { from => $uid, to => $nhood_uid });
		
		gsocialnet( from_user_id    => $nhood_uid,
		            rh_into_nodes   => $rh_n,
		            ra_into_edges   => $ra_e,
		            depth           => $args{ depth           } - 1,  # !!
		            on_user         => $args{ on_user         },
		            on_progress     => $args{ on_progress     },
		            ignore_nhood_gt => $args{ ignore_nhood_gt },
		            incl_friends    => $args{ incl_friends    },	
		            incl_followees  => $args{ incl_followees  },
		            incl_authors    => $args{ incl_authors    })  # Recursion not very deep
	}
}




=head2 C<void> greadsimilaraut(I<{ ... }>)

=over

=item * reads the Goodreads.com list of authors who are similar to the given author

=item * C<rh_into     =E<gt> hash reference (id =E<gt> L<%user|"%user">,...)>

=item * C<author_id   =E<gt> string>

=item * C<on_progress =E<gt> sub> see C<gmeter()> [optional]

=item * increments C<'_seen'> counter of each author if already in I<%$rh_into>

=back

=cut

sub greadsimilaraut
{
	my (%args) = @_;
	my $rh     =_require_arg( 'rh_into', $args{ rh_into });
	my $aid    = gverifyuser( $args{ author_id });
	my $pfn    = $args{ on_progress } // sub{};
	
	# Just 1 page:
	_extract_similar_authors( $rh, $aid, $pfn, _html( _similar_authors_url( $aid )));
}




=head2 C<void> gsearch(I<{ ... }>)

=over

=item * searches the Goodreads.com database for books that match a given phrase

=item * C<ra_into     =E<gt> array reference (L<%book|"%book">,...)> 

=item * C<phrase      =E<gt> string> with space separated keywords

=item * C<is_exact    =E<gt> bool> [optional, default 0]

=item * C<ra_order_by =E<gt> array reference> property names from C<L<%book|"%book">> 
                       [optional, default: 'stars', 'num_ratings', 'year']

=item * C<num_ratings =E<gt> int> only list books with at least N ratings [optional, default 0]

=item * C<on_progress =E<gt> sub> see C<gmeter()>  [optional]

=back

=cut

sub gsearch
{
	my (%args) = @_;
	my $ra     =    _require_arg( 'ra_into', $args{ ra_into });
	my $q      = lc _require_arg( 'phrase',  $args{ phrase  });
	my $pfn    = $args{ on_progress }  // sub{};
	my $n      = $args{ num_ratings }  // 0;
	my $e      = $args{ is_exact    }  // 0;
	my $ra_ord = $args{ ra_order_by }  // [ 'stars', 'num_ratings', 'year' ];
	my $pag    = 1;
	my @tmp;
	
	while( _extract_search_books( \@tmp, $pfn, _html( _search_url( $q, $pag++ )))) {};
	
	# Select and sort:
	@tmp = grep{ $_->{num_ratings}           >= $n } @tmp;
	@tmp = grep{ index( lc $_->{title}, $q ) != -1 } @tmp if $e;
	@$ra = sort  # TODO check index vs number of elements
	{
		$b->{ $ra_ord->[0] } <=> $a->{ $ra_ord->[0] } ||
		$b->{ $ra_ord->[1] } <=> $a->{ $ra_ord->[1] } ||
		$b->{ $ra_ord->[2] } <=> $a->{ $ra_ord->[2] }
	} @tmp;
}




=head2 C<string> amz_book_html( I<L<%book|"%book">> )

=over

=item * HTML body of an Amazon article page

=back

=cut

sub amz_book_html
{
	return _html( _amz_url( shift ) );
}





###############################################################################

=head1 PUBLIC REPORT-GENERATION HELPERS



=head2 C<string> ghtmlhead( I<$title, $ra_cols > )

=over

=item * returns a string with HTML boiler plate code for a table-based report

=item * $title: HTML title, Table caption

=item * $ra_cols: [ "Normal", ">Sort ASC", "<Sort DESC", "!Not sortable/searchable", "Right-Aligned:", ">Sort ASC, right-aligned:", ":Centered:" ]

=back

=cut

sub ghtmlhead
{
	my $title   = shift;  
	my $ra_cols = shift;
	my $jsorder = '';
	my $jscols  = '';
	my $th      = '';
	
	for my $i (0 .. $#{$ra_cols})
	{
		$jscols  .= "{ 'targets': $i, 'orderable': false, 'searchable': false }, " if $ra_cols->[$i] =~ /!/;
		$jscols  .= "{ 'targets': $i, 'className': 'dt-body-right'  }, "           if $ra_cols->[$i] =~ /^[^:].*:/;
		$jscols  .= "{ 'targets': $i, 'className': 'dt-body-center' }, "           if $ra_cols->[$i] =~ /:.*:/;
		$jsorder .= "[ $i, 'desc' ], "                                             if $ra_cols->[$i] =~ />/;
		$jsorder .= "[ $i, 'asc'  ], "                                             if $ra_cols->[$i] =~ /</;
		$th      .= '<th>' . ( $ra_cols->[$i] =~ /^[^a-zA-Z]*(.*?)[^a-zA-Z]*$/ ? $1 : '' ) . '</th>';  # Title w/o codes
	}
	
	return qq{
		<!DOCTYPE html>
		<html lang="en">
		<head>
		<meta charset="utf-8">
		<title>$title</title>
		<script src="https://ajax.googleapis.com/ajax/libs/jquery/2.1.1/jquery.min.js"></script>
		<script src="https://cdn.datatables.net/1.10.12/js/jquery.dataTables.min.js"></script>
		<link rel="stylesheet" property="stylesheet" type="text/css" media="all" 
				href="https://cdn.datatables.net/1.10.12/css/jquery.dataTables.min.css" />
		<script>
		/* Any HTML other than a table should be added via JS, so we have nothing but a plain
		   HTML table in the body which can be easily opened in office programs (Excel etc) */
		
		\$( document ).ready( function()
		{ 
			\$( 'table' ).DataTable(
			{
				"lengthMenu": [[ 7, 20, 50, 100, 250, 500, -1    ],   // Values
				               [ 7, 20, 50, 100, 250, 500, "All" ]],  // Labels
				"pageLength": 7,
				"autoWidth" : false,             // Adjust "Added by" col-width on re-ordering
				"pagingType": "full_numbers",
				"order"     : [ $jsorder ],
				"columnDefs": [ $jscols  ]
			});
			
			/* Only available with DataTable: */
			\$( 'body' ).append( '<p><strong>Order by multiple columns at the same time:</strong>'
					+ '<br>Use <kbd>Shift</kbd> and click on a column '
					+ '(added the clicked column as a secondary, tertiary etc ordering column)</p>' );
		});
		</script>
		<style>
			body { font-family: sans-serif; }
			table th { border: 1px solid #ccc; }
			kbd { 
				border-radius: 3px;
				border: 1px solid #b4b4b4;
				box-shadow: 0 1px 1px rgba(0, 0, 0, .2), 0 2px 0 0 rgba(255, 255, 255, .7) inset;
				display: inline-block;
				font-size: .85em;
				font-weight: 700;
				line-height: 1;
				padding: 2px 4px;
				white-space: nowrap; 
			}
		</style>
		</head>
		<body class="friendrated">
		<table class="hover row-border order-column" style="width:100%">
		<caption>Table: $title</caption>
		<thead> <tr> $th </tr> </thead>
		<tbody>
		};
}




=head2 C<string> ghtmlfoot()

=over

=item * returns a string with HTML boiler plate code for a table-based report

=back

=cut

sub ghtmlfoot
{
	return qq{
		</tbody>
		</table>
		</body>
		</html>
		};
}





###############################################################################

=head1 PRIVATE URL-GENERATION ROUTINES



=head2 C<string> _amz_url( I<L<%book|"%book">> )

=over

=item * Requires at least {isbn=E<gt>string}

=back

=cut

sub _amz_url
{
	my $book = shift;
	return $book->{isbn} ? "http://www.amazon.de/gp/product/$book->{isbn}" : undef;
}




=head2 C<string> _shelf_url( I<$user_id, $shelf_name, $page_number = 1> )

=over

=item * URL for a page with a list of books (not all books)

=item * "&print=true" allows 200 items per page with a single request, 
        which is a huge speed improvement over loading books from the "normal" 
        view with max 20 books per request.
        Showing 100 books in normal view is oddly realized by 5 AJAX requests
        on the Goodreads.com website.

=item * "&per_page" in print-view can be any number if you work with your 
        own shelf, otherwise max 200 if print view; ignored in non-print view;
        per_page>20 requires access with a cookie, see glogin()

=item * "&view=table" puts I<all> book data in code, although invisible (display=none)

=item * "&sort=rating" is important for `friendrated.pl` with its book limit:
        Some users read 9000+ books and scraping would take forever. 
        We sort lower-rated books to the end and I<could> just scrape the first pages:
        Even those with 9000+ books haven't top-rated more than 2700 books.

=item * "&shelf" supports intersection "shelf1%2Cshelf2" (comma)

=item * B<Warning:> changes to the URL structure will bust the file-cache

=back

=cut

sub _shelf_url  
{
	my $uid = shift;
	my $slf = shift;	
	my $pag = shift // 1;
	
	$slf =~ s/#/%23/g;  # "#ALL#" shelf
	$slf =~ s/,/%2C/g;  # Shelf intersection
	
	return "https://www.goodreads.com/review/list/${uid}?"
	     . "&print=true"
	     . "&shelf=${slf}"
	     . "&page=${pag}"
	     . "&sort=rating"
	     . "&order=d"
	     . "&view=table"
	     . "&title="
	     . "&per_page=200";
}




=head2 C<string> _followees_url( I<$user_id, $page_number = 1> )

=over

=item * URL for a page with a list of the people $user is following

=item * B<Warning:> changes to the URL structure will bust the file-cache

=back

=cut

sub _followees_url
{
	my $uid = shift;
	my $pag = shift // 1;
	return "https://www.goodreads.com/user/${uid}/following?page=${pag}";
}




=head2 C<string> _friends_url( I<$user_id, $page_number = 1> )

=over

=item * URL for a page with a list of people befriended to C<$user_id>

=item * "&sort=date_added" (as opposed to 'last online') avoids 
        moving targets while reading page by page

=item * "&skip_mutual_friends=false" because we're not doing
        this just for me

=item * B<Warning:> changes to the URL structure will bust the file-cache

=back

=cut

sub _friends_url
{
	my $uid = shift;
	my $pag = shift // 1;
	return "https://www.goodreads.com/friend/user/${uid}?"
	     . "&page=${pag}"
	     . "&skip_mutual_friends=false"
	     . "&sort=date_added";
}




=head2 C<string> _book_url( I<$book_id> )

=cut

sub _book_url
{
	my $bid = shift;
	return "https://www.goodreads.com/book/show/${bid}";
}




=head2 C<string> _user_url( I<$user_id, $is_author = 0> )

=cut

sub _user_url
{
	my $uid   = shift;
	my $is_au = shift // 0;
	return 'https://www.goodreads.com/'.( $is_au ? 'author' : 'user' )."/show/${uid}";
}




=head2 C<string> _revs_url( I<$book_id, $str_sort_newest_oldest = undef, 
		$search_text = undef, $rating = undef, $page_number = 1> )

=over

=item * "&sort=newest" and "&sort=oldest" reduce the number of reviews for 
        some reason (also observable on the Goodreads website), 
        so only use if really needed (&sort=default)

=item * "&search_text=example", max 30 hits, invalidates sort order argument

=item * "&rating=5"

=item * the maximum of retrievable pages is 10 (300 reviews), see
        https://www.goodreads.com/topic/show/18937232-why-can-t-we-see-past-page-10-of-book-s-reviews?comment=172163745#comment_172163745

=item * seems less throttled, not true for text-search

=back

=cut

sub _revs_url
{
	my $bid  = shift;
	my $sort = shift;
	my $rat  = shift;
	my $txt  = shift;
	   $txt  =~ s/\s+/+/g  if $txt;
	my $pag  = shift // 1;
	
	return "https://www.goodreads.com/book/reviews/${bid}?"
		.( $sort && !$txt ? "sort=${sort}&"       : '' )
		.( $txt           ? "search_text=${txt}&" : '' )
		.( $rat           ? "rating=${rat}&"      : '' )
		.( $txt           ? "" : "page=${pag}"         );
}




=head2 C<string> _rev_url( I<$review_id> )

=cut

sub _rev_url
{
	my $rid = shift;
	return "https://www.goodreads.com/review/show/${rid}";
}




=head2 C<string> _author_books_url( I<$user_id, $page_number = 1> )

=cut

sub _author_books_url
{
	my $uid = shift;
	my $pag = shift // 1;
	return "https://www.goodreads.com/author/list/${uid}?per_page=100&sort=popularity&page=${pag}";
}




=head2 C<string> _author_followings_url( I<$author_id, $page_number = 1> )

=cut

sub _author_followings_url
{
	my $uid = shift;
	my $pag = shift // 1;
	return "https://www.goodreads.com/author_followings?id=${uid}&page=${pag}";
}




=head2 C<string> _similar_authors_url( I<$author_id> )

=over

=item * page number > N just returns same page, so no easy stop criteria;
        not sure, if there's more than page, though

=back

=cut

sub _similar_authors_url
{
	my $uid = shift;
	return "https://www.goodreads.com/author/similar/${uid}";
}




=head2 C<string> _search_url( I<phrase_str, $page_number = 1> )

=over

=item * "&q=" URL-encoded, e.g., linux+%40+"hase (linux @ "hase)

=back

=cut

sub _search_url
{
	my $q   = uri_escape( shift );
	my $pag = shift;
	return "https://www.goodreads.com/search?page=${pag}&tab=books&q=${q}";
}




=head2 C<string> _user_groups_url( I<$user_id>, I<$page_number = 1> )

=cut

sub _user_groups_url
{
	my $uid = shift;
	my $pag = shift // 1;
	return "https://www.goodreads.com/group/list/${uid}?sort=title&page=${pag}";
}




=head2 C<string> _group_url( I<$group_id> )

=cut

sub _group_url
{
	my $gid = shift;
	return "https://www.goodreads.com/group/show/${gid}";
}




#==============================================================================

=head1 PRIVATE HTML-EXTRACTION ROUTINES



=head2 C<L<%book|"%book">> _extract_book( $book_page_html_str )

=cut

sub _extract_book
{
	my $htm = shift or return;
	my %bk;
	
	$bk{ id          } = $htm =~ /id="book_id" value="([^"]+)"/                         ? $1 : undef;
	
	return if !$bk{id};
	
	$bk{ isbn13      } = $htm =~ /<meta content='([^']+)' property='books:isbn'/        ? $1 : ''; # ISBN13
	$bk{ isbn        } = undef;  # TODO
	$bk{ img_url     } = $htm =~ /<meta content='([^']+)' property='og:image'/          ? $1 : '';
	$bk{ title       } = $htm =~ /<meta content='([^']+)' property='og:title'/          ? _dec_entities( $1 ) : '';
	$bk{ num_pages   } = $htm =~ /<meta content='([^']+)' property='books:page_count'/  ? $1 : $_NOBOOKIMGURL;
	$bk{ num_reviews } = $htm =~ /(\d+)[,.]?(\d*)[,.]?(\d*) review/    ? $1.$2.$3 : 0;  # 1,600,200 -> 1600200
	$bk{ num_ratings } = $htm =~ /(\d+)[,.]?(\d*)[,.]?(\d*) rating/    ? $1.$2.$3 : 0;  # 1,600,200 -> 1600200
	$bk{ avg_rating  } = $htm =~ /itemprop="ratingValue">\s*([0-9.]+)/ ? $1       : 0;  # # 3.77
	$bk{ stars       } = int( $bk{ avg_rating } + 0.5 );
	$bk{ url         } = _book_url( $bk{id} );
	$bk{ rh_author   } = undef;  # TODO
	$bk{ year        } = undef;  # TODO
	$bk{ year_edit   } = undef;  # TODO
	$bk{ format      } = undef;  # TODO
	
	return %bk;
}



=head2 C<L<%user|"%user">> _extract_user( $user_page_html_str )

=cut

sub _extract_user
{
	my $htm = shift or return;
	my %us;
	$us{ id } = $htm =~ /<meta property="og:url" content="https:\/\/www\.goodreads\.com\/user\/show\/(\d+)/ ? $1 : undef;
	
	return _extract_author( $htm ) if !$us{id};  # Might be redirected to author page
	
	my $fname = $htm =~ /<meta property="profile:first_name" content="([^"]+)/ ? _dec_entities( $1     )." " : "";
	my $lname = $htm =~ /<meta property="profile:last_name" content="([^"]+)/  ? _dec_entities( $1     )." " : "";
	my $uname = $htm =~ /<meta property="profile:username" content="([^"]+)/   ? _dec_entities( "($1)" )     : "";
	$us{ name       } = _trim( $fname.$lname.$uname );
	$us{ name_lf    } = $us{name};  # TODO
	$us{ num_books  } = $htm =~ /<meta content='[^']+ has (\d+)[,.]?(\d*)[,.]?(\d*) books/ ? $1.$2.$3 : 0;
	$us{ age        } = $htm =~ /<div class="infoBoxRowItem">[^<]*Age (\d+)/               ? $1 : 0;
	$us{ is_female  } = $htm =~ /<div class="infoBoxRowItem">[^<]*Female/                  ? 1  : 0;
	$us{ is_private } = $htm =~ /<div id="privateProfile"/                                 ? 1  : 0;
	$us{ is_staff   } = $htm =~ /Goodreads employee/                                       ? 1  : 0;
	$us{ img_url    } = $htm =~ /<meta property="og:image" content="([^"]+)/               ? $1 : $_NOUSERIMGURL;
	$us{ works_url  } = undef;
	$us{ is_friend  } = undef;
	$us{ is_author  } = 0;
	$us{ url        } = _user_url( $us{id}, $us{is_author} );
	$us{ _seen      } = 1;
	
	# Details string doesn't include Firstname/Middlename/Lastname, no Zip-Code
	# Also depedent on viewer's login status
	my $r = $htm =~ /Details<\/div>\s*<div class="infoBoxRowItem">([^<]+)/ ? _dec_entities( $1 ) : "";
	   $r =~ s/Age \d+,?//;        # remove optional Age part
	   $r =~ s/(Male|Female),?//;  # remove optional gender; TODO custom genders (neglectable atm)
	   $r =~ s/^\s+|\s+$//g;       # trim both ends
	   $r =~ s/\s*,\s*/, /g;       # "City , State" -> "City, State" (some consistency)
	$us{ residence } = ($r =~ m/any details yet/) ? '' : $r;  # remaining string is the residence (City, State)
	
	return %us;
}



=head2 C<L<%user|"%user">> _extract_author( $user_page_html_str )

=cut

sub _extract_author
{
	my $htm = shift or return;
	my %us;
	$us{ id         } = $htm =~ /<meta content='https:\/\/www\.goodreads\.com\/author\/show\/(\d+)/ ? $1 : undef;
	$us{ name       } = $htm =~ /<meta content='([^']+)' property='og:title'>/ ? _dec_entities( $1 ) : "";
	$us{ name_lf    } = $us{name};   # TODO
	$us{ img_url    } = $htm =~ /<meta content='([^']+)' property='og:image'>/ ? $1 : $_NOUSERIMGURL;
	$us{ is_staff   } = $htm =~ /<h3 class="right goodreadsAuthor">/           ? 1  : 0;
	$us{ is_private } = 0;
	$us{ is_female  } = undef;  # TODO
	$us{ works_url  } = _author_books_url( $us{id} );
	$us{ residence  } = undef;
	$us{ num_books  } = $htm =~ /=reviews">(\d+)[,.]?(\d*)[,.]?(\d*) ratings</ ? $1.$2.$3 : 0; # Closest we can get
	$us{ is_friend  } = undef;
	$us{ is_author  } = 1;
	$us{ url        } = _user_url( $us{id}, $us{is_author} );
	$us{ _seen      } = 1;
	
	return %us;
}



=head2 C<bool> _extract_books( I<$rh_books, $on_book_fn, $on_progress_fn, $shelf_tableview_html_str> )

=over

=item * I<$rh_books>: C<(id =E<gt> L<%book|"\%book">,...)>

=back

=cut

sub _extract_books
{
	my $rh  = shift;
	my $bfn = shift;
	my $pfn = shift;
	my $htm = shift or return 0;
	my $ret = 0;
	
	# TODO verify if shelf is the given one or redirected by GR to #ALL# bc misspelled	
	
	while( $htm =~ /<tr id="review_\d+" class="bookalike review">(.*?)<\/tr>/gs ) # each book row
	{	
		my $row = $1;
		my %au;
		my %bk;
		
		my $tit = $row =~ />title<\/label><div class="value">\s*<a[^>]+>\s*(.*?)\s*<\/a>/s  ? $1 : '';
		   $tit =~ s/\<[^\>]+\>//g;          # remove HTML tags "Title <span>(Volume 2)</span>"
		   $tit =~ s/( {1,}|[\r\n])/ /g;     # reduce spaces
		   $tit = _dec_entities( $tit );  # &quot -> "
		
		my $dadd  = $row =~ />date added<\/label><div class="value">\s*<span title="([^"]*)/ ? $1 : undef;
		my $dread = $row =~ /<span class="date_read_value">([^<]*)/                          ? $1 : undef;
		my $tadd  = $dadd  ? Time::Piece->strptime( $dadd,  "%B %d, %Y" ) : $_EARLIEST; # "June 19, 2015"
		my $tread = $dread ? eval{   Time::Piece->strptime( $dread, "%b %d, %Y" ); } ||         # "Sep 06, 2018"
		                     eval{   Time::Piece->strptime( $dread, "%b %Y"     ); } ||         # "Sep 2018"
		                     eval{   Time::Piece->strptime( $dread, "%Y"        ); } ||         # "2018"
		                     $_EARLIEST
		                   : $_EARLIEST;
		
		$au{ id              } = $row =~ /author\/show\/([0-9]+)/       ? $1                            : undef;
		$au{ name_lf         } = $row =~ /author\/show\/[^>]+>([^<]+)/  ? _dec_entities( $1 ) : '';
		$au{ name            } = $au{name_lf};  # Shelves already list names with "lastname, firstname"
		$au{ residence       } = undef;
		$au{ url             } = _user_url( $au{id}, 1 );
		$au{ works_url       } = _author_books_url( $au{id} );
		$au{ is_author       } = 1;
		$au{ is_private      } = 0;
		$au{ _seen           } = 1;
		
		$bk{ rh_author       } = \%au;
		$bk{ id              } = $row =~ /data-resource-id="([0-9]+)"/                                                ? $1 : undef;
		$bk{ year            } = $row =~         />date pub<\/label><div class="value">.*?(-?\d+)\s*</s               ? $1 : 0;  # "2017" and "Feb 01, 2017" and "-50" (BC) and "177"
		$bk{ year_edit       } = $row =~ />date pub edition<\/label><div class="value">.*?(-?\d+)\s*</s               ? $1 : 0;  # "2017" and "Feb 01, 2017" and "-50" (BC) and "177"
		$bk{ isbn            } = $row =~             />isbn<\/label><div class="value">\s*([0-9X\-]*)/                ? $1 : '';
		$bk{ isbn13          } = $row =~           />isbn13<\/label><div class="value">\s*([0-9X\-]*)/                ? $1 : '';
		$bk{ avg_rating      } = $row =~       />avg rating<\/label><div class="value">\s*([0-9\.]*)/                 ? $1 : 0;
		$bk{ num_pages       } = $row =~        />num pages<\/label><div class="value">\s*<nobr>\s*([0-9]*)/          ? $1 : 0;
		$bk{ num_ratings     } = $row =~      />num ratings<\/label><div class="value">\s*(\d+)[,.]?(\d*)[,.]?(\d*)/  ? $1.$2.$3 : 0;
		$bk{ format          } = $row =~           />format<\/label><div class="value">\s*((.*?)(\s*<))/s             ? _dec_entities( $2 ) : ""; # also trims ">  avc def  <"
		$bk{ user_read_count } = $row =~     /># times read<\/label><div class="value">\s*([0-9]*)/                   ? ($1?$1:0) : 0;
		$bk{ user_num_owned  } = $row =~            />owned<\/label><div class="value">\s*([0-9]*)/                   ? ($1?$1:0) : 0;
		$bk{ user_date_added } = $tadd;
		$bk{ user_date_read  } = $tread;
		$bk{ user_rating     } = () = $row =~ /staticStar p10/g;        # Counts occurances
		$bk{ ra_user_shelves } = [];      # TODO;
		$bk{ num_reviews     } = undef;  # Not available here!
		$bk{ img_url         } = $row =~ /<img [^>]* src="([^"]+)"/                                                   ? $1 : $_NOBOOKIMGURL;
		$bk{ review_id       } = $row =~ /review\/show\/([0-9]+)"/                                                    ? $1 : undef;
		$bk{ title           } = _trim( $tit );
		$bk{ url             } = _book_url( $bk{id} );
		$bk{ stars           } = int( $bk{ avg_rating } + 0.5 );
		
		$ret++ unless exists $rh->{$bk{id}};  # Don't count duplicates (multiple shelves)
		$rh->{ $bk{id} } = \%bk if $rh;
		$bfn->( \%bk );
	}
	
	$pfn->( $ret );
	return $ret;
}




=head2 C<bool> _extract_author_books( I<$rh_books, $r_limit, $on_book_fn, $on_progress_fn, $html_str> )

=over

=item * I<$rh_books>: C<(id =E<gt> L<%book|"\%book">,...)>

=item * I<$r_limit>: is counted to zero

=back

=cut

sub _extract_author_books
{
	# Book without title on https://www.goodreads.com/author/list/1094257
	
	my $rh      = shift;
	my $r_limit = shift;
	my $bfn     = shift;
	my $pfn     = shift;
	my $htm     = shift or return 0;
	my $auimg   = $htm =~ /(https:\/\/images.gr-assets.com\/authors\/.*?\.jpg)/gs  ? $1 : $_NOUSERIMGURL;
	my $aid     = $htm =~ /author\/show\/([0-9]+)/                                 ? $1 : undef;
	my $aunm    = $htm =~ /<h1>Books by ([^<]+)/                                   ? _dec_entities( $1 ) : '';
	my $ret     = 0;
	
	return $ret if $$r_limit == 0;
	
	while( $htm =~ /<tr itemscope itemtype="http:\/\/schema.org\/Book">(.*?)<\/tr>/gs )
	{
		my $row = $1;
		my %au;
		my %bk;
		
		$au{ id          } = $aid;
		$au{ name        } = _trim( $aunm );
		$au{ name_lf     } = $au{name};  # TODO
		$au{ residence   } = undef;
  		$au{ img_url     } = $auimg;
		$au{ url         } = _user_url( $aid, 1 );
		$au{ works_url   } = _author_books_url( $aid );
		$au{ is_author   } = 1;
		$au{ is_private  } = 0;
		$au{ _seen       } = 1;
		
		$bk{ rh_author   } = \%au;
		$bk{ id          } = $row =~ /book\/show\/([0-9]+)/               ? $1       : undef;
		$bk{ num_ratings } = $row =~ /(\d+)[,.]?(\d*)[,.]?(\d*) rating/   ? $1.$2.$3 : 0;  # 1,600,200 -> 1600200
		$bk{ img_url     } = $row =~ /src="([^"]+)/                       ? $1       : $_NOBOOKIMGURL;
		$bk{ title       } = $row =~ /<span itemprop='name'[^>]*>([^<]+)/ ? _dec_entities( $1 ) : '';
		$bk{ url         } = _book_url( $bk{id} );
		$bk{ isbn        } = undef;  # TODO?
		$bk{ isbn13      } = undef;  # TODO?
		$bk{ format      } = undef;  # TODO?
		$bk{ num_pages   } = undef;  # TODO?
		$bk{ year        } = undef;  # TODO?
		$bk{ year_edit   } = undef;  # TODO?
		
		$ret++; # Count duplicates too: 10 books of author A, 9 of B; called for single author
		$rh->{ $bk{id} } = \%bk;
		$bfn->( \%bk );
		$$r_limit--;
		last if !$$r_limit;
	}
	
	$pfn->( $ret );
	return $ret;
}




=head2 C<bool> _extract_followees( I<$rh_users, $on_progress_fn, $incl_authors, $discard_threshold, $following_page_html_str> )

=over

=item * I<$rh_users>: C<(user_id =E<gt> L<%user|"\%user">,...)>

=back

=cut

sub _extract_followees
{
	my $rh      = shift;
	my $pfn     = shift;
	my $iau     = shift;
	my $dishold = shift;
	my $htm     = shift or return 0;
	my $ret     = 0;
	my $pgcount = $htm =~ />(\d+)<\/a> <a class="next_page"/ ? $1 : 1;
	my $total   = $pgcount * 30;  # Items per page
	
	return 0 if $total > $dishold;
	
	while( $htm =~ /<div class='followingItem elementList'>(.*?)<\/a>/gs )
	{
		my $row = $1;
		my $uid = $row =~   /\/user\/show\/([0-9]+)/   ? $1 : undef;
		my $aid = $row =~ /\/author\/show\/([0-9]+)/   ? $1 : undef;	
		my %us;
		
		$us{ id        } = $uid ? $uid : $aid;
		$us{ name      } = $row =~ /img alt="([^"]+)/  ? _dec_entities( $1 ) : '';
		$us{ name_lf   } = $us{name};  # TODO
		$us{ img_url   } = $row =~ /src="([^"]+)/      ? $1                        : $_NOUSERIMGURL;
		$us{ works_url } = $aid                        ? _author_books_url( $aid ) : '';
		$us{ url       } = _user_url( $us{id}, $aid );
		$us{ is_author } = defined $aid;
		$us{ is_friend } = 0;
		$us{ _seen     } = 1;
		$us{ residence } = undef;  # TODO?
		$us{ num_books } = undef;  # TODO?
		
		next if !$iau && $us{is_author};
		$ret++;
		$rh->{ $us{id} } = \%us;
	}
	
	$pfn->( $ret );
	return $ret;
}




=head2 C<bool> _extract_friends( I<$rh_users, $on_progress_fn, $incl_authors, $discard_threshold, $friends_page_html_str> )

=over

=item * I<$rh_users>: C<(user_id =E<gt> L<%user|"\%user">,...)> 

=back

=cut

sub _extract_friends
{
	my $rh      = shift;
	my $pfn     = shift;
	my $iau     = shift;
	my $dishold = shift;
	my $htm     = shift or return 0;
	my $ret     = 0;
	my $total   = $htm =~ /Showing \d+-\d+ of (\d+)/ ? $1 : -1;
	
	return 0 if $total > $dishold;
	
	while( $htm =~ /<tr>\s*<td width="1%">(.*?)<\/td>/gs )
	{
		my $row = $1;
		my $uid = $row =~   /\/user\/show\/([0-9]+)/   ? $1 : undef;
		my $aid = $row =~ /\/author\/show\/([0-9]+)/   ? $1 : undef;
		my %us;
		
		$us{ id        } = $uid ? $uid : $aid;
		$us{ name      } = $row =~ /img alt="([^"]+)/  ? _dec_entities( $1 ) : '';
		$us{ name_lf   } = $us{name};  # TODO
		$us{ img_url   } = $row =~     /src="([^"]+)/  ? $1                        : $_NOUSERIMGURL;
		$us{ works_url } = $aid                        ? _author_books_url( $aid ) : '';
		$us{ url       } = _user_url( $us{id}, $aid );
		$us{ is_author } = defined $aid;
		$us{ is_friend } = 1;
		$us{ _seen     } = 1;
		$us{ residence } = undef;  # TODO?
		$us{ num_books } = undef;  # TODO?
		
		next if !$iau && $us{ is_author };
		$ret++;
		$rh->{ $us{id} } = \%us;
	}
	
	$pfn->( $ret );
	return $ret;
}




=head2 C<string> _conv_uni_codepoints( I<$string> )

=over

=item Convert Unicode codepoints such as \u003c

=back

=cut

sub _conv_uni_codepoints
{
	# TODO: "Illegal hexadecimal digit 'n' ignored"	
	my $str = shift;
	$str    =~ s/\\u(....)/ pack 'U*', hex($1) /eg; 
	return $str;
}




=head2 C<string> _dec_entities( I<$string> )

=cut

sub _dec_entities
{
	return _trim( decode_entities( shift ));
}




=head2 C<$value> _require_arg( I<$name, $value> )

=cut

sub _require_arg
{
	my $nam = shift;
	my $val = shift;
	croak( _errmsg( $_ENO_BADARG, $nam )) if !defined $val;
	return $val;
}




=head2 C<string> _trim( I<$string> )

=cut

sub _trim
{
	my $s = shift;
	$s =~ s/^\s+|\s+$//g;
	return $s;
}




=head2 C<bool> _extract_revs( I<$rh_revs, $on_progress_fn, $filter_fn, $since_time_piece, $reviews_xhr_html_str> )

=over

=item * I<$rh_revs>: C<(review_id =E<gt> L<%review|"\%review">,...)>

=back

=cut

sub _extract_revs
{
	my $rh           = shift;
	my $pfn          = shift;
	my $ffn          = shift;
	my $since_tpiece = shift;
	my $htm          = shift or return 0;  # < is \u003c, > is \u003e,  " is \" literally
	my $bid          = $htm =~ /\/book\/reviews\/([0-9]+)/  ? $1 : undef;
	my $ret          = 0;
	
	while( $htm =~ /div id=\\"review_\d+(.*?)div class=\\"clear/gs )
	{		
		my $row = $1;
		
		# Avoid username "0" eval to false somewhere -> "0" instead of 0
		#
		# [x] Parse-error "Jan 01, 1010" https://www.goodreads.com/review/show/1369192313
		# [x] img alt=\"David T\"   
		# [x] img alt=\"0\"
		# [ ] img alt="\u0026quot;Greg Adkins\u0026quot;\"  TODO
		
		my $dat        = $row =~ /([A-Z][a-z]+ \d+, (19[7-9][0-9]|2\d{3}))/  ? $1 : undef;
		my $dat_tpiece = $dat ? Time::Piece->strptime( $dat, '%b %d, %Y' ) : $_EARLIEST; 
		
		next if $dat_tpiece < $since_tpiece;
		
		my %us;
		my %rv;
		
		# There's a short and a long text variant both saved in $row
		my $txts = $row =~ /id=\\"freeTextContainer[^"]+"\\u003e(.*?)\\u003c\/span/                     ? _dec_entities( $1 ) : '';
		my $txt  = $row =~ /id=\\"freeText[0-9]+\\" style=\\"display:none\\"\\u003e(.*?)\\u003c\/span/  ? _dec_entities( $1 ) : '';
		   $txt  = $txts if length( $txts ) > length( $txt );
		
   		$txt =~ s/\\"/"/g;
		$txt = _conv_uni_codepoints( $txt );
		$txt =~ s/<br \/>/\n/g;
		
		$us{ id         } = $row =~ /\/user\/show\/([0-9]+)/ ? $1 : undef;
		$us{ name       } = $row =~ /img alt=\\"(.*?)\\"/    ? ($1 eq '0' ? '"0"' : _dec_entities( $1 )) : '';
		$us{ name_lf    } = $us{name};  # TODO
  		$us{ img_url    } = $_NOUSERIMGURL;  # TODO
		$us{ url        } = _user_url( $us{id} );
		$us{ _seen      } = 1;
		
		$rv{ id         } = $row =~ /\/review\/show\/([0-9]+)/ ? $1 : undef;
		$rv{ text       } = $txt;
		$rv{ rating     } = () = $row =~ /staticStar p10/g;  # Count occurances
		$rv{ rating_str } = $rv{rating} ? ('[' . ($rv{text} ? (length($rv{text})>160?'T':'t') : '*') x $rv{rating} . ' ' x (5-$rv{rating}) . ']') : '[added]';
		$rv{ url        } = _rev_url( $rv{id} );
		$rv{ date       } = $dat_tpiece;
		$rv{ book_id    } = $bid;
		$rv{ rh_user    } = \%us;
		
		if( $ffn->( \%rv ) )  # Filter
		{
			$ret++ unless exists $rh->{$rv{id}};  # Don't count duplicates (multiple searches for same book)
			$rh->{ $rv{id} } = \%rv;
		}
	}
	
	$pfn->( $ret );
	return $ret;
}




=head2 C<bool> _extract_similar_authors( I<$rh_into, $author_id_to_skip, 
			$on_progress_fn, $similar_page_html_str> )

=cut

sub _extract_similar_authors
{
	my $rh          = shift;
	my $uid_to_skip = shift;
	my $pfn         = shift;
	my $htm         = shift or return 0;
	my $ret         = 0;
	
	# All nice JSON since 2019-03-25, but as long as it's simple
	# we still regex and avoid dependencies to a JSON module
	# 
	while( $htm =~ /<div data-react-class="ReactComponents.SimilarAuthorsList" data-react-props="([^"]*)/gs )
	{	
		my $json = _conv_uni_codepoints( _dec_entities( $1 ));
		
		while( $json =~ /\{"author":\{"id":([^,]+),"name":"([^"]+)",[^\{]*"profileImage":"([^"]+)/gs )
		{
			my %au;
			$au{ id      } = $1;
			$au{ name    } = _trim( $2 );
			$au{ img_url } = $3;
			
			next if $au{id} eq $uid_to_skip;
			
			$ret++;  # Incl. duplicates: 10 similar to author A, 9 to B; A and B can incl same similar authors
					
			if( exists $rh->{$au{id}} )
			{
				$rh->{$au{id}}->{_seen}++;  # similarauth.pl
				next;
			}
			
			$au{ name_lf    } = $au{name};  # TODO
			$au{ url        } = _user_url( $au{id}, 1 );
			$au{ works_url  } = _author_books_url( $au{id} );
			$au{ is_author  } = 1;
			$au{ is_private } = 0;
			$au{ _seen      } = 1;
			$au{ residence  } = undef;  # TODO?
			$au{ num_books  } = undef;  # TODO
			
			$rh->{ $au{id} } = \%au;
		}
	}
	
	$pfn->( $ret );
	return $ret;
}




=head2 C<bool> _extract_search_books( I<$ra_books, $on_progress_fn, $search_result_html_str>  )

=over

=item * result pages sometimes have different number of items: 
        P1: 20, P2: 16, P3: 19

=item * website says "about 75 results" but shows 70 (I checked that manually).
        So we fake "100%" to the progress indicator function at the end,
        otherwise it stops with "93%".

=item * I<ra_books>: C<(L<%book|"\%book">,...)> 

=back

=cut

sub _extract_search_books
{
	my $ra  = shift;
	my $pfn = shift;
	my $htm = shift or return 0;
	my $ret = 0;
	my $max = $htm =~ /Page \d+ of about (\d+) results/  ? $1 : 0;
	
	# We check against the stated number of results, alternative exit 
	# conditions: Page 100 (Page 100+x == Page 100), or "NO RESULTS."
	if( scalar @$ra >= $max )
	{
		$pfn->( 1, 1 );
		return 0;
	}
	
	while( $htm =~ /<tr itemscope itemtype="http:\/\/schema.org\/Book">(.*?)<\/tr>/gs )
	{
		my $row = $1;
		my %au;
		my %bk;
		
		$au{ id              } = $row =~ /\/author\/show\/([0-9]+)/  ? $1 : undef;
		$au{ name            } = $row =~ /<a class="authorName" [^>]+><span itemprop="name">([^<]+)/  ? _dec_entities( $1 ) : '';
		$au{ name_lf         } = $au{name};  # TODO
		$au{ url             } = _user_url        ( $au{id}, 1 );
		$au{ works_url       } = _author_books_url( $au{id}    );
		$au{ img_url         } = $_NOUSERIMGURL;
		$au{ is_author       } = 1;
		$au{ is_private      } = 0;
		$au{ _seen           } = 1;
		
		$bk{ id              } = $row =~ /book\/show\/([0-9]+)/               ? $1       : undef;
		$bk{ num_ratings     } = $row =~ /(\d+)[,.]?(\d*)[,.]?(\d*) rating/   ? $1.$2.$3 : 0;  # 1,600,200 -> 1600200
		$bk{ avg_rating      } = $row =~ /([0-9.,]+) avg rating/              ? $1       : 0;  # 3.8
		$bk{ year            } = $row =~ /published\s+(-?\d+)/                ? $1       : 0;  # "2018", "-50" (BC)
		$bk{ img_url         } = $row =~ /src="([^"]+)/                       ? $1       : $_NOBOOKIMGURL;
		$bk{ title           } = $row =~ /<span itemprop='name'[^>]*>([^<]+)/ ? _dec_entities( $1 ) : '';
		$bk{ url             } = _book_url( $bk{id} );
		$bk{ stars           } = int( $bk{ avg_rating } + 0.5 );
		$bk{ rh_author       } = \%au;
		$bk{ ra_user_shelves } = [];
		
		push( @$ra, \%bk );
		$ret++;  # There are no duplicates, no extra checks
	}
	
	$pfn->( $ret, $max );
	return $ret;
}




=head2 C<bool> _extract_user_groups( I<$rh_into, $on_group_fn, on_progress_fn, $groups_html_str> )

=cut

sub _extract_user_groups
{
	my $rh  = shift;
	my $gfn = shift;
	my $pfn = shift;
	my $htm = shift or return 0;
	my $ret = 0;
	
	while( $htm =~ /<div class="elementList">(.*?)<div class="clear">/gs )
	{
		my $row = $1;
		my %gp;
		
		$gp{ id          } = $row =~ /\/group\/show\/(\d+)/               ? $1 : undef;
		$gp{ name        } = $row =~ /<a class="groupName" [^>]+>([^<]+)/ ? _dec_entities( $1 ) : "";
		$gp{ num_members } = $row =~ /(\d+) member/                       ? $1 : 0;  # "8397"
		$gp{ img_url     } = $row =~ /<img src="([^"]+)/                  ? $1 : $_NOGROUPIMGURL;
		$gp{ url         } = _group_url( $gp{id} );
		
		$rh->{$gp{id}} = \%gp;
		$ret++;
		$gfn->( \%gp );
	}
	
	$pfn->( $ret );
	return $ret;
}




=head2 C<string> _extract_csrftok(I< $html >)

=over

=item Example:
	my $csrftok = _extract_csrftok( _html( _user_url( $uid ) ) );
	$curl->setopt( $curl->CURLOPT_HTTPHEADER, [ "X-CSRF-Token: ${csrftok}",

=back

=cut

sub _extract_csrftok
{
	my $htm = shift or return 0;
	return $htm =~ /<meta name="csrf-token" content="([^"]*)/ ? $1 : undef;
}




###############################################################################

=head1 PRIVATE I/O PLUMBING SUBROUTINES




=head2 C<int> _check_page( I<$any_html_str> )

=over

=item * returns I<$_ENO_XXX> constants

=item * warn if sign-in page (https://www.goodreads.com/user/sign_in) or in-page message

=item * warn if "page unavailable, Goodreads request took too long"

=item * warn if "page not found" 

=item * error if page unavailable: "An unexpected error occurred. 
	We will investigate this problem as soon as possible"

=item * error if over capacity (TODO UNTESTED):
        "<?>Goodreads is over capacity.</?> 
        <?>You can never have too many books, but Goodreads can sometimes
        have too many visitors. Don't worry! We are working to increase 
        our capacity.</?>
        <?>Please reload the page to try again.</?>
        <a ...>get the latest on Twitter</a>"
        https://pbs.twimg.com/media/DejvR6dUwAActHc.jpg
        https://pbs.twimg.com/media/CwMBEJAUIAA2bln.jpg
        https://pbs.twimg.com/media/CFOw6YGWgAA1H9G.png  (with title)

=item * error if maintenance mode (TODO UNTESTED):
        "<?>Goodreads is down for maintenance.</?>
        <?>We expect to be back within minutes. Please try again soon!<?>
        <a ...>Get the latest on Twitter</a>"
        https://pbs.twimg.com/media/DgKMR6qXUAAIBMm.jpg
        https://i.redditmedia.com/-Fv-2QQx2DeXRzFBRKmTof7pwP0ZddmEzpRnQU1p9YI.png

=item * error if website temporarily unavailable (TODO UNTESTED):
        "Our website is currently unavailable while we make some improvements
        to our service. We'll be open for business again soon,
        please come back shortly to try again. <?>
        Thank you for your patience." (No Alice error)
        https://i.gr-assets.com/images/S/compressed.photo.goodreads.com/hostedimages/1404319071i/10224522.png

=back

=cut

sub _check_page
{
	my $htm = shift or return $_ENO_NOHTML;
	
	# Try to be precise, don't stop just because someone wrote a pattern 
	# in his review or a book title. Characters such as < and > are 
	# encoded in user texts:
	
	return $_ENO_GRSIGNIN
		if $htm =~ /<head>\s*<title>\s*Sign in\s*<\/title>/s 
		|| $htm =~ /<head>\s*<title>\s*Sign Up\s*<\/title>/s;
		
	return $_ENO_GR400
		if $htm =~ /<head>\s*<title>\s*400 Bad Request\s*<\/title>/s;
	
	return $_ENO_GR404
		if $htm =~ /<head>\s*<title>\s*Page not found\s*<\/title>/s;
	
	return $_ENO_GRUNAVAIL
		if $htm =~ /Our website is currently unavailable while we make some improvements/s; # TODO improve
			
	return $_ENO_GRUNEXPECT
		if $htm =~ /<head>\s*<title>\s*Goodreads - unexpected error\s*<\/title>/s;
	
	return $_ENO_GRCAPACITY
		if $htm =~ /<head>\s*<title>\s*Goodreads is over capacity\s*<\/title>/s;
	
	return $_ENO_GRMAINTNC
		if $htm =~ /<head>\s*<title>\s*Goodreads is down for maintenance\s*<\/title>/s;
	
	return 0;
}




=head2 C<void> _updcookie(I< $string_with_changed_fields >)

=over

=item updates "_session_id2" for X-CSRF-Token, "csid", "u" (user?). "p" (password?)

=back

=cut

sub _updcookie
{
	my $changes = shift or return;
	my %new     = _cookie2hash( $changes );
	my %c       = _cookie2hash( $_cookie );
	$c{$_}      = $new{$_} for keys %new;   # Merge new and old
	$_cookie    = join( '; ', map{ "$_=$c{$_}" } keys %c );
}

sub _cookie2hash  # @TODO: ugly
{
	my @fields = split( /;/, shift // '' );
	my %r      = ();
	for my $f (@fields)
	{
		$f =~ /^\s*([^=]+)=(.+)$/;
		$r{$1}=$2 if $1 && $2;
	}
	return %r;
}





=head2 C<void> _setcurlopts(I< $curl_ref >, I< $url_str >)

=over

=item Sets default options for GET, POST, PUT, DELETE

=back

=cut

sub _setcurlopts
{
	my $curl = shift;	
	my $url  = shift // '';
	
	# Misc:
	$curl->setopt( $curl->CURLOPT_FOLLOWLOCATION, 1           );
	$curl->setopt( $curl->CURLOPT_USERAGENT,      $_USERAGENT );
	$curl->setopt( $curl->CURLOPT_COOKIE,         $_cookie    ) if $_cookie;
	$curl->setopt( $curl->CURLOPT_HEADER,         0           );
	$curl->setopt( $curl->CURLOPT_HEADERFUNCTION, sub
	{
		my $chunk = shift;
		_updcookie( $chunk =~ /Set-Cookie:(.*)/i ? $1 : undef );  # for CSRF-Token
		return length( $chunk );
	});
	
	# Performance options:
	# - don't hang too long, better disconnect and retry
	# - reduce number of SSL handshakes (reuse connection)
	# - reduce SSL overhead
	# 
	# The module works without any of these options, but probably slower.
	# All `eval` due to https://github.com/andre-st/goodreads/issues/20
	eval{ $curl->setopt( $curl->CURLOPT_TIMEOUT,        60  ); };
	eval{ $curl->setopt( $curl->CURLOPT_CONNECTTIMEOUT, 60  ); };
	eval{ $curl->setopt( $curl->CURLOPT_FORBID_REUSE,   0   ); };  # CURL default
	eval{ $curl->setopt( $curl->CURLOPT_FRESH_CONNECT,  0   ); };  # CURL default
	eval{ $curl->setopt( $curl->CURLOPT_TCP_KEEPALIVE,  1   ); };  
	eval{ $curl->setopt( $curl->CURLOPT_TCP_KEEPIDLE,   120 ); }; 
	eval{ $curl->setopt( $curl->CURLOPT_TCP_KEEPINTVL,  60  ); };
	eval{ $curl->setopt( $curl->CURLOPT_SSL_VERIFYPEER, 0   ); };
	eval{ $curl->setopt( $curl->CURLOPT_MAXREDIRS,      5   ); };
	
	# Tweaks:
	if( index( $url, '/book/reviews/' ) != -1 )  # "No HTML body" error sometimes
	{
		$curl->setopt( $curl->CURLOPT_COOKIE,         undef );  # Cookie triggers error
		$curl->setopt( $curl->CURLOPT_HEADERFUNCTION, undef );  # No cookie updates
	}
}




=head2 C<string> _html( I<$url, $warn_level = $_ENO_WARN, $can_cache = 1> )

=over

=item * HTML body of a web document

=item * caches documents (if I<$can_cache> is true)

=item * retries on errors

=back

=cut

sub _html
{
	my $url       = shift or return '';
	my $warnlevel = shift // $_ENO_WARN;
	my $cancache  = shift // 1;
	my $retry     = $_MAXRETRIES;
	my $htm;
	
	$htm = $_cache->get( $url ) 
		if $cancache && $_cache_age ne $EXPIRES_NOW;
	
	return $htm 
		if defined $htm;
	
DOWNLOAD:
	state $curl;
	my    $curlret;
	my    $errno;
	
	$curl = WWW::Curl::Easy->new if !$curl;
	_setcurlopts( $curl, $url );
	$curl->setopt( $curl->CURLOPT_URL,       $url  );
	$curl->setopt( $curl->CURLOPT_REFERER,   $url  );  # https://www.goodreads.com/...  [F5]
	$curl->setopt( $curl->CURLOPT_HTTPGET,   1     );
	$curl->setopt( $curl->CURLOPT_WRITEDATA, \$htm );
	
	$curlret = $curl->perform;
	$errno   = $curlret == 0 ? _check_page( $htm ) : $_ENO_CURL;
	
	warn( _errmsg( $errno, $url, $curl->strerror( $curlret ), $curl->errbuf ))
		if $errno >= $warnlevel;
	
	if( $errno >= $_ENO_CRIT 
	||( $errno >= $_ENO_ERROR && $retry-- > 0 ))
	{
		warn( $errno >= $_ENO_CRIT 
				? $_MSG_RETRYING_FOREVER
				: sprintf( $_MSG_RETRYING_NTIMES, $retry + 1 ));
		
		$curl = undef;  # disconnect
		sleep( $_RETRYDELAY_SECS );
		goto DOWNLOAD;
	}
	
DONE:	
	$_cache->set( $url, $htm, $_cache_age )
		if $cancache && $errno == 0;
	
	return $htm;
}



1;
__END__


