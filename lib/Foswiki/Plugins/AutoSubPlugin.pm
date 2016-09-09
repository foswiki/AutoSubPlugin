# Copyright 2015 Applied Research Laboratories, the University of
# Texas at Austin.
#
#    This file is part of AutoSubPlugin.
#
#    AutoSubPlugin is free software: you can redistribute it and/or
#    modify it under the terms of the GNU General Public License as
#    published by the Free Software Foundation, either version 3 of
#    the License, or (at your option) any later version.
#
#    AutoSubPlugin is distributed in the hope that it will be
#    useful, but WITHOUT ANY WARRANTY; without even the implied
#    warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#    See the GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with AutoSubPlugin.  If not, see <http://www.gnu.org/licenses/>.
#
# Author: John Knutson
#
# Provide a mechanism for automatically applying substitutions of
# content as wiki pages are rendered.

=begin TML

---+ package Foswiki::Plugins::AutoSubPlugin

Define a set of Foswiki macros to perform text substitutions when
rendering wiki topics.  This may be used, for example, to
automatically turn non-wikiword text into a link.

=cut

package Foswiki::Plugins::AutoSubPlugin;

# Always use strict to enforce variable scoping
use strict;
use warnings;

use Foswiki::Func    ();    # The plugins API
use Foswiki::Meta    ();    # The metadata API
use Foswiki::Plugins ();    # For the API version

use version; our $VERSION = version->declare("v1.0.0");
our $RELEASE          = '1.0.0';
our $SHORTDESCRIPTION = 'Define text substitutions for rendered wiki topics';

# Do not search the plugin topic for settings.
our $NO_PREFS_IN_TOPIC = 1;

#
# Plugin settings passed in URL or by preferences
#
my $debugDefault;     # Debug mode
my @protectedTags;    # HTML tags to be protected from substitutions

#
# request variables
#
my $baseWeb;
my $baseTopic;

#
# Internal flags
#
my $isInitialized;   # prevent multiple macro processing per wiki page
my $indent;          # indentation value for debug output
my $pageRenderIdx;   # for debugging to distinguish between preRenderingHandlers

#
# Storage for links
#
my %seenSubWebTopics;
my %links;
my %linkLocations;
my %doNotSub;

#
# Internal constants
#
my $errFmtStart      = "<font color=\"red\"><nop>AutoSubPlugin Error: ";
my $errFmtEnd        = "</font>";
my $wordBreak        = "[^\\[<>\\]\\w]";
my $defaultProtected = "pre noautolink dot verbatim plantuml";
my $metaType = "AUTOSUB";        # metadata type tag
my $linkTag  = "AUTOSUBLINK";    # tag used for removed links

sub _writeDebug {
    my $tag = 'AutoSubPlugin ';
    $tag =~ s/^(.*)/' ' x $indent . $1/e;
    &Foswiki::Func::writeDebug( $tag . $_[0] )
      if $debugDefault;
}

sub debugFuncStart {
    _writeDebug( "+ " . $_[0] );
    $indent += 3;
}

sub debugFuncEnd {
    $indent -= 3;
    _writeDebug( "- " . $_[0] );
}

sub _stackDebug {
    eval { require Devel::StackTrace; };
    return _writeDebug("warning: Devel::StackTrace package not available")
      if ($@);
    return _writeDebug( Devel::StackTrace->new( no_args => 1 )->as_string() );
}

sub _dumpDebug {
    eval { require Data::Dumper; };
    return _writeDebug("warning: Data::Dumper package not available: $@")
      if ($@);

    #$Data::Dumper::Maxrecurse = 1;
    #$Data::Dumper::Maxdepth = 1;
    return _writeDebug( Data::Dumper->Dump( $_[0] ) );
}

=begin TML

---++ initPlugin($topic, $web, $user) -> $boolean
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$user= - the login name of the user
   * =$installWeb= - the name of the web the plugin topic is in
     (usually the same as =$Foswiki::cfg{SystemWebName}=)

*REQUIRED*

Called to initialise the plugin. If everything is OK, should return
a non-zero value. On non-fatal failure, should write a message
using =Foswiki::Func::writeWarning= and return 0. In this case
%<nop>FAILEDPLUGINS% will indicate which plugins failed.

In the case of a catastrophic failure that will prevent the whole
installation from working safely, this handler may use 'die', which
will be trapped and reported in the browser.

__Note:__ Please align macro names with the Plugin name, e.g. if
your Plugin is called !FooBarPlugin, name macros FOOBAR and/or
FOOBARSOMETHING. This avoids namespace issues.

=cut

sub initPlugin {
    my ( $baseTopicInit, $baseWebInit, $user, $installWeb ) = @_;

    $indent        = 0;
    $pageRenderIdx = 0;

    # Get plugin debug flag - possibly dangerous to do this before the
    # version check.
    $debugDefault = Foswiki::Func::getPreferencesFlag('AUTOSUBPLUGIN_DEBUG');

    $baseTopic = $baseTopicInit;
    $baseWeb   = $baseWebInit;

    debugFuncStart("initPlugin $baseTopic, $baseWeb");

    # check for Plugins.pm versions
    if ( $Foswiki::Plugins::VERSION < 2.0 ) {
        Foswiki::Func::writeWarning( 'Version mismatch between ',
            __PACKAGE__, ' and Plugins.pm' );
        debugFuncEnd("initPlugin $baseTopic, $baseWeb");
        return 0;
    }

    $isInitialized = 0;

    # make sure structures are clean
    %seenSubWebTopics = ();
    %links            = ();
    %linkLocations    = ();
    %doNotSub         = ();

    my $protectedTagsStr =
      Foswiki::Func::getPreferencesValue('AUTOSUBPLUGIN_PROTECTED')
      || $defaultProtected;
    @protectedTags = split( / +/, $protectedTagsStr );

    Foswiki::Func::registerTagHandler( 'AUTOSUB',   \&_AUTOSUB );
    Foswiki::Func::registerTagHandler( 'AUTOSUBS',  \&_AUTOSUBS );
    Foswiki::Func::registerTagHandler( 'NOAUTOSUB', \&_NOAUTOSUB );

    debugFuncEnd("initPlugin $baseTopic, $baseWeb");

    # Plugin correctly initialized
    return 1;
}

# Return an HTML/wiki formatted string containing the given error message.
sub macroError {

    # $_[0] - an error message to provide the user
    return $errFmtStart . $_[0] . $errFmtEnd;
}

# Implements processing of the AUTOSUB macro, which populates the
# substitution hash.
sub _AUTOSUB {
    my ( $session, $params, $topic, $web, $topicObject ) = @_;

    # $session  - a reference to the Foswiki session object
    #             (you probably won't need it, but documented in Foswiki.pm)
    # $params=  - a reference to a Foswiki::Attrs object containing
    #             parameters.
    #             This can be used as a simple hash that maps parameter names
    #             to values, with _DEFAULT being the name for the default
    #             (unnamed) parameter.
    # $topic    - name of the topic in the query
    # $web      - name of the web in the query
    # $topicObject - a reference to a Foswiki::Meta object containing the
    #             topic the macro is being rendered in (new for foswiki 1.1.x)
    debugFuncStart("_AUTOSUB");
    my $key         = $params->{'_DEFAULT'}   || $params->{'name'};
    my $replacement = $params->{'repl'}       || '';
    my $noWikiWord  = $params->{'noWikiWord'} || '';
    if ( !defined $key ) {
        return macroError('AUTOSUB macro missing name parameter');
    }
    if ( !defined $replacement ) {
        return macroError('AUTOSUB macro missing replacement parameter');
    }
    if ($noWikiWord) {

        #_writeDebug("_AUTOSUB noWikiWord set for $key");
        $noWikiWord = '<nop>';
    }
    $links{$key}         = $replacement;
    $linkLocations{$key} = "$web.$topic";
    _writeDebug(
"_AUTOSUB key $key set links{$key} to $links{$key} @ $linkLocations{$key}"
    );
    debugFuncEnd("_AUTOSUB");
    return "";
}

# Implements processing of the AUTOSUBS macro, which generates a table
# of contents of the substitution hash.
sub _AUTOSUBS {
    my ( $session, $params, $topic, $web, $topicObject ) = @_;

    # $session  - a reference to the Foswiki session object
    #             (you probably won't need it, but documented in Foswiki.pm)
    # $params=  - a reference to a Foswiki::Attrs object containing
    #             parameters.
    #             This can be used as a simple hash that maps parameter names
    #             to values, with _DEFAULT being the name for the default
    #             (unnamed) parameter.
    # $topic    - name of the topic in the query
    # $web      - name of the web in the query
    # $topicObject - a reference to a Foswiki::Meta object containing the
    #             topic the macro is being rendered in (new for foswiki 1.1.x)
    my $key;
    my $rv = "";

    #debugFuncStart("_AUTOSUBS");
    $rv =
        "%TABLE{sort=\"on\" datavalign=\"middle\"}%\n"
      . "| *Automatic Subs/Rewrites* |||\n"
      . "| *Word* | *Substitution* | *Location* |\n";
    foreach $key ( keys %links ) {

        # TODO figure out how to get the formatting shown rather than parsed
        #$rv .= "| <nop>$key | <literal>$links{$key}</literal> |\n";
        $rv .=
"| <nop>$key | <verbatim class=\"tml\">$links{$key}</verbatim> | $linkLocations{$key} |\n";
    }
    $rv .= "\n";

    #debugFuncEnd("_AUTOSUBS");
    return $rv;
}

# Implements processing of the NOAUTOSUB macro, which disables the
# substituion of the given keyword.
sub _NOAUTOSUB {
    my ( $session, $params, $topic, $web, $topicObject ) = @_;

    # $session  - a reference to the Foswiki session object
    #             (you probably won't need it, but documented in Foswiki.pm)
    # $params=  - a reference to a Foswiki::Attrs object containing
    #             parameters.
    #             This can be used as a simple hash that maps parameter names
    #             to values, with _DEFAULT being the name for the default
    #             (unnamed) parameter.
    # $topic    - name of the topic in the query
    # $web      - name of the web in the query
    # $topicObject - a reference to a Foswiki::Meta object containing the
    #             topic the macro is being rendered in (new for foswiki 1.1.x)
    my $key = $params->{'_DEFAULT'} || $params->{'name'};
    if ( !defined $key ) {
        return macroError('NOAUTOSUB macro missing name parameter');
    }

    #debugFuncStart("_NOAUTOSUB");
    $doNotSub{$key} = 1;

    #debugFuncEnd("_NOAUTOSUB");
    return "";
}

=begin TML

---++ afterCommonTagsHandler($text, $topic, $web, $meta )
   * =$text= - text to be processed
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$meta= - meta-data object for the topic MAY BE =undef=
This handler is called after Foswiki has completed expansion of %MACROS%.
It is designed for use by cache plugins. Note that when this handler
is called, &lt;verbatim> blocks are present in the text.

*NOTE*: This handler is called once for each call to
=commonTagsHandler= i.e. it may be called many times during the
rendering of a topic.

*NOTE:* meta-data is _not_ embedded in the text passed to this
handler.

*NOTE:* Read the developer supplement at
Foswiki:Development.AddToZoneFromPluginHandlers if you are calling
=addToZone()= from this handler

=cut

sub afterCommonTagsHandler {
    my ( $text, $topic, $web, $included, $meta ) = @_;
    my $removed = {};
    my $key;
    my $i;

    # for debugging
    my $workPath = Foswiki::Func::getWorkArea("AutoSubPlugin");
    my $bPath    = $workPath . "/afterCommonTagsHandler-before.debug";
    my $aPath    = $workPath . "/afterCommonTagsHandler-after.debug";
    my $beforeHash;
    my $beforePutBack;
    my $beforeTakeOut;
    my $afterTakeOut;
    my $rexp;
    my $subMade = 0;    # if non-zero a substitution was made
    $pageRenderIdx++;

    use Regexp::Common;
    my $bp = $RE{balanced}{ -parens => '{}' };

    # empty page is empty.
    return unless defined $_[0];

    #debugFuncStart("afterCommonTagsHandler");
    my ( $dbgPackage, $dbgFilename, $dbgLine ) = caller;
    _writeDebug(
"afterCommonTagsHandler(text,$topic,$web,$included,meta) caller: $dbgPackage $dbgFilename $dbgLine"
    );

    # hide other macros so we don't perform substitutions within them.
    my $regexMacro = qr/(%($Foswiki::regex{tagNameRegex})$bp\%)/;
    if ($debugDefault) {
        my $origBText = Foswiki::Func::readFile($bPath);
        my $newBText =
            $origBText
          . "\n--$pageRenderIdx----$web----$topic--(CT1)----------------\n"
          . $_[0];
        Foswiki::Func::saveFile( $bPath, $newBText );

        $beforeTakeOut = $_[0];
    }
    for $i ( 0 .. $#protectedTags ) {
        _writeDebug("Taking out HTML tag $protectedTags[$i]");
        $_[0] = Foswiki::takeOutBlocks( $_[0], $protectedTags[$i], $removed );
    }

    # hack to temporarily hide nop/macro stuff
    $_[0] =~ s/$regexMacro/<AUTOSUBMACRO>$1<\/AUTOSUBMACRO>/gs;
    $_[0] =~ s/([^<\w])!(\w+)/$1<AUTOSUBBANG>$2<\/AUTOSUBBANG>/gs;
    $_[0] =~ s/<nop>(\w+)/<AUTOSUBNOP>$1<\/AUTOSUBNOP>/gs;
    $_[0] = Foswiki::takeOutBlocks( $_[0], 'AUTOSUBBANG',  $removed );
    $_[0] = Foswiki::takeOutBlocks( $_[0], 'AUTOSUBMACRO', $removed );
    $_[0] = Foswiki::takeOutBlocks( $_[0], 'AUTOSUBNOP',   $removed );
    $_[0] = takeOutLinks( $_[0], $removed );

    if ($debugDefault) {
        $afterTakeOut = $_[0];
    }

    # used for debugging only
    my $happySubsTopic = "";
    my $happySubsWeb   = "";
    my %topicSubs      = ();

    # perform the substitutions
    foreach $key ( keys %links ) {
        if ( !defined $doNotSub{$key} ) {
            $rexp = "(" . $wordBreak . ")" . $key . "(" . $wordBreak . ")";
            my $substitute = Foswiki::Func::decodeFormatTokens( $links{$key} );

            #_writeDebug("s/$rexp/\$1$substitute\$2/gm");
            $subMade = $_[0] =~ s/$rexp/$1$substitute$2/gm;
            if ($subMade) {
                push( @{ $topicSubs{"$web.$topic"} }, $key );
                $happySubsTopic = $topic;
                $happySubsWeb   = $web;
                _writeDebug("sub made $key $topic $web");
            }

            #_writeDebug("sub done");
        }
    }
    if ( defined $topicSubs{"$web.$topic"} ) {
        _writeDebug(
            "afterCommonTagsHandler $web.$topic $happySubsWeb.$happySubsTopic "
              . join( ' ', @{ $topicSubs{"$web.$topic"} } ) );
    }
    else {
        _writeDebug(
"afterCommonTagsHandler $web.$topic $happySubsWeb.$happySubsTopic EMPTY"
        );
    }

    if ($debugDefault) {
        $beforePutBack = $_[0];
    }

    # restore removed blocks
    # must be done in reverse order of takeOutBlocks
    # restore nop stuff and macros
    putBackLinks( \$_[0], $removed );
    Foswiki::putBackBlocks( \$_[0], $removed, 'AUTOSUBNOP',   'nop' );
    Foswiki::putBackBlocks( \$_[0], $removed, 'AUTOSUBMACRO', 'AUTOSUBMACRO' );
    Foswiki::putBackBlocks( \$_[0], $removed, 'AUTOSUBBANG',  'AUTOSUBBANG' );
    $_[0] =~ s/<AUTOSUBBANG>(\w+)<\/AUTOSUBBANG>/!$1/gs;
    $_[0] =~ s/<\/?AUTOSUBMACRO>//gs;

    # remove the superfluous "</nop>"
    $_[0] =~ s/<\/nop>//gs;
    for $i ( reverse 0 .. $#protectedTags ) {
        _writeDebug("Putting back HTML tag $protectedTags[$i]");
        Foswiki::putBackBlocks( \$_[0], $removed, $protectedTags[$i],
            $protectedTags[$i] );
    }

    if ($debugDefault) {
        my $afterHash    = "(removed to avoid data dumper dependency)";
        my $afterPutBack = $_[0];

        my $origAText = Foswiki::Func::readFile($aPath);
        my $newAText =
            $origAText
          . "\n--$pageRenderIdx----$web----$topic--(CT2)----------------\n"
          . $_[0]
          . "\n======================================================"
          . "\n===BEFORE TAKE OUT===================================="
          . "\n======================================================\n"
          . $beforeTakeOut
          . "\n======================================================"
          . "\n===AFTER TAKE OUT====================================="
          . "\n======================================================\n"
          . $afterTakeOut

          # . "\n======================================================"
          # . "\n===BEFORE PUT BACK===================================="
          # . "\n======================================================\n"
          # . $beforeHash . "\n"
          # . $beforePutBack
          . "\n======================================================"
          . "\n===AFTER PUT BACK====================================="
          . "\n======================================================\n"
          . $afterHash . "\n"
          . $afterPutBack . "\n";
        Foswiki::Func::saveFile( $aPath, $newAText );
    }

    #debugFuncEnd("afterCommonTagsHandler");
}

# provide replacements for link text
sub _handleLink {
    my ( $link, $map ) = @_;
    use Foswiki qw($BLOCKID $OC $CC);
    _writeDebug("_handleLink(\"$link\")");
    my $placeholder = $linkTag . $Foswiki::BLOCKID;
    $Foswiki::BLOCKID++;
    $map->{$placeholder}{text}   = $link;
    $map->{$placeholder}{params} = '';      # unused, not an XML tag
    return $Foswiki::OC . $placeholder . $Foswiki::CC;
}

# Works like Foswiki::takeOutBlocks, except that it is specific to
# explicit links, e.g. [[SomethingSomething][click me]] or
# http://www.google.com.
# Returns $text with blocks removed.
# IMO this should be part of the Foswiki core, but it is not.
sub takeOutLinks {
    my ( $intext, $map ) = @_;

    # =$text= - Text to process
    # =\%map= - Reference to a hash to contain the removed blocks.
    #  Should be the same map used by takeOutBlocks, if both are being
    #  used.
    my $out = $intext;
    _writeDebug("takeOutLinks()");
    _writeDebug("intext:");
    _writeDebug($intext);

    # The code in Render.pm didn't use the outside / which results in
    # only the inner parts of the link expression being stored in $1.
    # I need the whole thing.
    $out =~ s/(\[\[([^\]\[\n]+)\](\[([^\]\n]+)\])?\])/_handleLink($&,$map)/ge;
    use Foswiki::Render ();
    my $STARTWW = $Foswiki::Render::STARTWW;
    my $ENDWW   = $Foswiki::Render::ENDWW;

    # URI - don't apply if the URI is surrounded by url() to avoid naffing
    # CSS
    $out =~ s/(^|(?<!url)[-*\s(|])
               ($Foswiki::regex{linkProtocolPattern}:
                   ([^\s<>"]+[^\s*.,!?;:)<|]))/
                     _handleLink($&,$map)/geox;

    # Normal mailto:foo@example.com (mailto: part optional)
    $out =~ s/$STARTWW((mailto\:)?
                   $Foswiki::regex{emailAddrRegex})$ENDWW/
                   _handleLink( $&,$map )/gemx;
    return $out;
}

# Reverses the actions of takeOutLinks.
# Returns $text with links added back
sub putBackLinks {
    my ( $text, $map ) = @_;

    # \$text - reference to text to process
    # \%map - map placeholders to links removed by takeOutLinks

    foreach my $placeholder ( keys %$map ) {
        if ( $placeholder =~ /^$linkTag\d+$/ ) {
            my $val = $map->{$placeholder}{text};
            _writeDebug("replace \"$placeholder\" with \"$val\"");
            $$text =~ s/$Foswiki::OC$placeholder$Foswiki::CC/$val/;
            delete( $map->{$placeholder} );
        }
    }
}

1;
