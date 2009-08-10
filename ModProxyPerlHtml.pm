#------------------------------------------------------------------------------
# Project  : Reverse Proxy HTML link rewriter
# Name     : ModProxyPerlHtml.pm
# Language : perl 5
# Authors  : Gilles Darold, gilles at darold dot net
# Copyright: Copyright (c) 2005-2008: Gilles Darold - All rights reserved -
# Description : This mod_perl2 module is a replacement for mod_proxy_html.c
#		with far better URL HTML rewriting.
# Usage    : See documentation in this file with perldoc.
#------------------------------------------------------------------------------
# This program is free software; you can redistribute it and/or modify it under
# the same terms as Perl itself.
#------------------------------------------------------------------------------
package Apache2::ModProxyPerlHtml;
use strict qw(vars);
use warnings;

require mod_perl2;

use Apache2::Connection ();
use Apache2::RequestRec;
use Apache2::RequestUtil;
use APR::Table;
use APR::URI;
use base qw(Apache2::Filter);
use Apache2::Const -compile => qw(OK DECLINED :conn_keepalive);
use constant BUFF_LEN => 8000;
use Apache2::ServerRec;
use Apache2::URI;

$Apache2::ModProxyPerlHtml::VERSION = '2.6';

%Apache2::ModProxyPerlHtml::linkElements = (
	'a'       => ['href'],
	'applet'  => ['archive', 'codebase', 'code'],
	'area'    => ['href'],
	'bgsound' => ['src'],
	'blockquote' => ['cite'],
	'body'    => ['background'],
	'del'     => ['cite'],
	'embed'   => ['pluginspage', 'src'],
	'form'    => ['action'],
	'frame'   => ['src', 'longdesc'],
	'iframe'  => ['src', 'longdesc'],
	'ilayer'  => ['background'],
	'img'     => ['src', 'lowsrc', 'longdesc', 'usemap'],
	'input'   => ['src', 'usemap'],
	'ins'     => ['cite'],
	'isindex' => ['action'],
	'head'    => ['profile'],
	'layer'   => ['background', 'src'],
	'link'    => ['href'],
	'object'  => ['classid', 'codebase', 'data', 'archive', 'usemap'],
	'q'       => ['cite'],
	'script'  => ['src', 'for'],
	'table'   => ['background'],
	'td'      => ['background'],
	'th'      => ['background'],
	'tr'      => ['background'],
	'xmp'     => ['href'],
);

sub handler
{
	my $f = shift;

	my $debug = $f->r->dir_config->get('ProxyHTMLVerbose');
	if ($debug && $debug =~ /(on|1)/i) {
		$debug = 1;
	} else {
		$debug = 0;
	}

	# Thing we do at the first chunk
	my $content_type = $f->r->content_type() || '';
	unless ($f->ctx) {
		$f->r->headers_out->unset('Content-Length');
		my @pattern = $f->r->dir_config->get('ProxyHTMLURLMap');
		my @rewrite = $f->r->dir_config->get('ProxyHTMLRewrite');
		my $ct = $f->ctx;
		$ct->{data} = '';
		foreach my $p (@pattern) {
			push(@{$ct->{pattern}}, $p);
		}
		foreach my $p (@rewrite) {
			push(@{$ct->{rewrite}}, $p);
		}
		$f->ctx($ct);
	}
	# Thing we do on all invocations
	my $ctx = $f->ctx;
	while ($f->read(my $buffer, BUFF_LEN)) {
		$ctx->{data} .= $buffer;
		$ctx->{keepalives} = $f->c->keepalives;
		$f->ctx($ctx);
	}
	# Thing we do at end
	if ($f->seen_eos) { 
		# Skip content that should not have links
		my $parsed_uri = $f->r->construct_url();
		my $encoding = $f->r->headers_in->{'Accept-Encoding'} || '';
	       	# if Accept-Encoding: gzip,deflate try to uncompress
		if ($encoding =~ /gzip|deflate/) {
			use IO::Uncompress::AnyInflate qw(anyinflate $AnyInflateError) ;
			my $output = '';
			anyinflate  \$ctx->{data} => \$output or print STDERR "anyinflate failed: $AnyInflateError\n";
			if ($ctx->{data} ne $output) {
				$ctx->{data} = $output;
			} else {
				$encoding = '';
			}
		}
		
		if ($content_type =~ /(text\/javascript|text\/html|text\/css|application\/.*javascript)/) {
			# Replace links if pattern match
			foreach my $p (@{$ctx->{pattern}}) {
				my ($match, $substitute) = split(/[\s\t]+/, $p);
				&link_replacement(\$ctx->{data}, $match, $substitute, $parsed_uri);

			}
			# Rewrite code if rewrite pattern match
			foreach my $p (@{$ctx->{rewrite}}) {
				my ($match, $substitute) = split(/[\s\t]+/, $p);
				&rewrite_content(\$ctx->{data}, $match, $substitute, $parsed_uri);

			}
		}

		if ($encoding =~ /gzip/) {
			use IO::Compress::Gzip qw(gzip $GzipError) ;
			my $output = '';
			my $status = gzip \$ctx->{data} => \$output or die "gzip failed: $GzipError\n";
			$ctx->{data} = $output;
		} elsif ($encoding =~ /deflate/) {
			use IO::Compress::Deflate qw(deflate $DeflateError) ;
			my $output = '';
			my $status = deflate \$ctx->{data} => \$output or die "deflate failed: $DeflateError\n";
			$ctx->{data} = $output;
		}
		$f->ctx($ctx);

		# Dump datas out
		$f->print($f->ctx->{data});
		my $c = $f->c;
		if ($c->keepalive == Apache2::Const::CONN_KEEPALIVE && $ctx->{data} && $c->keepalives > $ctx->{keepalives}) {
			if ($debug) {
				warn "[ModProxyPerlHtml] cleaning context for keep alive request\n";
			}
			$ctx->{data} = '';
			$ctx->{pattern} = ();
			$ctx->{keepalives} = $c->keepalives;
		}
			
	}

	return Apache2::Const::OK;
}

sub link_replacement
{
	my ($data, $pattern, $replacement, $uri) = @_;

	return if (!$$data);

	my $old_terminator = $/;
	$/ = '';
	my @TODOS = ();
	my $i = 0;
	# Replace standard link into attributes of any element
	foreach my $tag (keys %Apache2::ModProxyPerlHtml::linkElements) {
		next if ($$data !~ /<$tag/i);
		foreach my $attr (@{$Apache2::ModProxyPerlHtml::linkElements{$tag}}) {
			while ($$data =~ s/(<$tag[\t\s]+[^>]*\b$attr=['"]*)($replacement|$pattern)([^'"\s>]+)/NEEDREPLACE_$i$$/i) {
				push(@TODOS, "$1$replacement$3");
				$i++;
			}
		
		}
	}
	# Replace all links in javascript code
	$$data =~ s/([^\\]['"])($replacement|$pattern)([^'"]*['"])/$1$replacement$3/ig;
	# Some use escaped quote - Do you have better regexp ?
	$$data =~ s/(\&quot;)($replacement|$pattern)(.*\&quot;)/$1$replacement$3/ig;

	# Try to set a fully qualified URI
	$uri =~ s/$replacement.*//;
        # Replace meta refresh URLs
	$$data =~ s/(<meta\b[^>]+content=['"]*.*url=)($replacement|$pattern)([^>]+)/$1$uri$replacement$3/i;
	# Replace base URI
	$$data =~ s/(<base\b[^>]+href=['"]*)($replacement|$pattern)([^>]+)/$1$uri$replacement$3/i;

	# CSS have url import call, most of the time not quoted
	$$data =~ s/(url\(['"]*)($replacement|$pattern)(.*['"]*\))/$1$replacement$3/ig;

	# Javascript have image object or other with a src method.
	$$data =~ s/(\.src[\s\t]*=[\s\t]*['"]*)($replacement|$pattern)(.*['"]*)/$1$replacement$3/ig;
	
	# The single ended tag broke mod_proxy parsing
	$$data =~ s/($replacement|$pattern)>/\/>/ig;
	
	# Replace todos now
	for ($i = 0; $i <= $#TODOS; $i++) {

		$$data =~ s/NEEDREPLACE_$i$$/$TODOS[$i]/i;
	}

	$/ = $old_terminator;

}

sub rewrite_content
{
	my ($data, $pattern, $replacement, $uri) = @_;

	return if (!$$data);

	my $old_terminator = $/;
	$/ = '';

	# Rewrite things in code (case sensitive)
	$$data =~ s/$pattern/$replacement/g;

	$/ = $old_terminator;

}


1;

__END__

=head1 DESCRIPTION

Apache2::ModProxyPerlHtml is a mod_perl2 replacement of the Apache2
module mod_proxy_html.c use to rewrite HTML links for a reverse proxy.

Apache2::ModProxyPerlHtml is very simple and has far better parsing/replacement
of URL than the original C code. It also support meta tag, CSS, and javascript
URL rewriting and can be use with compressed HTTP. You can now replace any
code by other, like changing images name or anything else.
 

=head1 AVAIBILITY

You can get the latest version of Apache2::ModProxyPerlHtml from
CPAN (http://search.cpan.org/).

=head1 PREREQUISITES

You must have Apache2, mod_perl2 and IO::Compress::Zlib perl module
installed.

You also need to install the mod_proxy Apache module. See
documentation at http://httpd.apache.org/docs/2.0/mod/mod_proxy.html

=head1 INSTALLATION

	% perl Makefile.PL
	% make && make install

=head1 APACHE CONFIGURATION

Here is the DSO module loading I use:

    LoadModule deflate_module modules/mod_deflate.so
    LoadModule headers_module modules/mod_headers.so
    LoadModule proxy_module modules/mod_proxy.so
    LoadModule proxy_connect_module modules/mod_proxy_connect.so
    LoadModule proxy_ftp_module modules/mod_proxy_ftp.so
    LoadModule proxy_http_module modules/mod_proxy_http.so
    LoadModule ssl_module modules/mod_ssl.so
    LoadModule perl_module  modules/mod_perl.so


Here is the reverse proxy configuration I use :

    ProxyRequests Off
    ProxyPreserveHost Off
    ProxyPass       /webmail/  http://webmail.domain.com/
    ProxyPass       /webcal/  http://webcal.domain.com/
    ProxyPass       /intranet/  http://intranet.domain.com/

    PerlInputFilterHandler Apache2::ModProxyPerlHtml
    PerlOutputFilterHandler Apache2::ModProxyPerlHtml
    SetHandler perl-script
    PerlSetVar ProxyHTMLVerbose "On"
    LogLevel Info

    # URL rewriting
    RewriteEngine   On
    RewriteLog      "/var/log/apache/rewrite.log"
    RewriteLogLevel 9
    # Add ending '/' if not provided
    RewriteCond     %{REQUEST_URI}  ^/mail$
    RewriteRule     ^/(.*)$ /$1/    [R]
    RewriteCond     %{REQUEST_URI}  ^/planet$
    RewriteRule     ^/(.*)$ /$1/    [R]
    # Add full path to the CGI to bypass the index.html redirect that may fail
    RewriteCond     %{REQUEST_URI}  ^/calendar/$
    RewriteRule     ^/(.*)/$ /$1/cgi-bin/wcal.pl    [R]
    RewriteCond     %{REQUEST_URI}  ^/calendar$
    RewriteRule     ^/(.*)$ /$1/cgi-bin/wcal.pl     [R]

    <Location /webmail/>
    	ProxyPassReverse /
    	PerlAddVar ProxyHTMLURLMap "/ /webmail/"
	PerlAddVar ProxyHTMLURLMap "http://webmail.domain.com /webmail"
	# Use this to disable compressed HTTP
	#RequestHeader   unset   Accept-Encoding
    </Location>

    <Location /webcal/>
    	ProxyPassReverse /
    	PerlAddVar ProxyHTMLURLMap "/ /webcal/"
	PerlAddVar ProxyHTMLURLMap "http://webcal.domain.com /webcal"
    </Location>

    <Location /intranet/>
    	ProxyPassReverse /
    	PerlAddVar ProxyHTMLURLMap "/ /intranet/"
	PerlAddVar ProxyHTMLURLMap "http://intranet.samse.fr /intranet"
    	PerlAddVar ProxyHTMLURLMap "/intranet/webmail /webmail"
    	PerlAddVar ProxyHTMLURLMap "/intranet/webcal /webcal"
    </Location>

Note that this example set filterhandlers globally, you can set it
in any <Location> part to set it locally and avoid calling this
Apache module globally.

If you want to rewrite some code on the fly, like changing images filename
you can use the perl variable ProxyHTMLRewrite under the location directive
as follow:

    <Location /webmail/>
	...
    	PerlAddVar ProxyHTMLRewrite "/logo/image1.png /images/logo1.png"
	...
    </Location>

this will replace each occurence of '/logo/image1.png' by '/images/logo1.png'
in the entire stream (html, javascript or css).
Note the this kind of substitution is done after all other proxy related
replacements.

In certain condition some javascript code will be replaced by error, for
example:

	imgUp.src = '/images/' + varPath + '/' + 'up.png';

will be rewritten like this:

	imgUp.src = '/URL/images/' + varPath + '/URL/' + 'up.png';

To avoid the second replacement, write your JS code like that:

	imgUp.src = '/images/' + varPath + unescape('%2F') + 'up.png';


=head1 BUGS 

Apache2::ModProxyPerlHtml is still under development and is pretty
stable. Please send me email to submit bug reports or feature
requests.

=head1 COPYRIGHT

Copyright (c) 2005-2008 - Gilles Darold

All rights reserved.  This program is free software; you may redistribute
it and/or modify it under the same terms as Perl itself.

=head1 AUTHOR

Apache2::ModProxyPerlHtml was created by :

	Gilles Darold
	<gilles at darold dot net>

and is currently maintain by me.

