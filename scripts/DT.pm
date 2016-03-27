package DT;

require Exporter;

use strict;
use Carp;
use Data::Dumper;
use utf8;

binmode(STDOUT, ":utf8");


sub print_dynamic_table {
    my ($head, $rows, $opts) = @_;
    my $extra_css = $opts->{extra_css};
    my $no_html_header = $opts->{no_html_header};
    my $no_html_end = $opts->{no_html_end};
    my $title = $opts->{title};

    print_html_header($title) unless $no_html_header;
    print $extra_css;

    print "  <table class=dynamicTable>\n";
    print "  <thead>\n";

    my $c = "column_1_";
    my $ci = 1;
    print "    <tr>". join('', map { "<th class=$c".++$ci.">$_</th>" } @$head) . "</tr>\n";
    print "  </thead>\n";

    for my $row (@$rows) {
        print "    <tr>";
        print join('', map { "<td>$_</td>" } @$row);
        print "    </tr>\n";
    }

    print "  </table>\n";
    print_html_end() unless $no_html_end;
}

sub print_html_header {
    my ($title) = @_;
    $title ||= "Dynamic Table";

    print <<End_of_Header;
<html>
<head>
<meta http-equiv="Content-Type" content="text/html;charset=UTF-8" />
End_of_Header

print "<title>$title</title>\n";

    print <<"End_of_Style";

  <script type="text/javascript" src="http://bioseed.mcs.anl.gov/~fangfang/js/dt.js"></script>
  <script language="JavaScript" type="text/javascript" src="http://bioseed.mcs.anl.gov/~fangfang/js/ms.js"></script>
</head>
<body>

<style type="text/css">
  .dynamicTable {
    font-size: 13px;
    font-family: sans-serif;
    border-width: 1px;
    border-spacing: 0;
    border-style: outset;
    border-color: gray;
    border-collapse: separate;
    background-color: white;
  }
  .dynamicTable th {
    border-width: 1px;
    padding: 3px;
    border-style: inset;
    border-color: rgb(170, 170, 170);
    background-color: white;
    -moz-border-radius: ;
  }
  .dynamicTable td.header {
    font-size: 15px;
    border-width: 1px;
    padding: 3px;
    border-style: inset;
    border-color: rgb(170, 170, 170);
    background-color: white;
    -moz-border-radius: ;
  }
  .dynamicTable td {
    border-width: 1px;
    padding: 2px;
    white-space: nowrap;
    text-align: center;
    border-style: inset;
    border-color: rgb(170, 170, 170);
    -moz-border-radius: ;
  }
  .dynamicTable tr:nth-child(even) {
    background-color: rgba(0, 0, 255, 0.08); /* greenish blue, 8% alpha */
  }
  .centeredImage {
    text-align:center;
    vertical-align:middle;
    margin-top:0px;
    margin-bottom:0px;
    padding:0px;
  }
  .centerText {
    text-align:center;
    white-space:nowrap;
  }
  .wrap {
    white-space:normal;
  }
  .mouseover {
    font-size: 13px;
    font-family: sans-serif;
  }
  .mouseoverTable {
    font-size: 13px;
    font-family: sans-serif;
  }
  .mouseoverTable td {
    white-space: nowrap;
  }
  .transparent a:link, a:visited {
    font-size: 9px;
    color: rgba(0, 0, 255, 0.0);
  }
</style>

<style type="text/css">
    <!--
      table {
      }
    -->
</style>
End_of_Style

}

sub print_html_end {
    print <<End_of_Table;
  <div class=transparent>
  <a title="Dynamic Table - A javascript table sort widget." href="http://dynamictable.com">Quick and easy table sorting powered by Dynamic Table</a>
  </div>
</body>
</html>
End_of_Table

}

sub mouseover_javascript {
    '<script language="JavaScript" type="text/javascript" src="ms.js"></script>';
}

sub span_mouseover {
    my ($text, $title, $html, $menu, $parent, $titlecolor, $bodycolor) = @_;
    $title ||= "Title bar <i>text</i> goes here";
    $html  ||= "Body text.<br />This can have any <b>HTML</b> tags you like.";
    my $tip = mouseover($title, $html, $menu, $parent, $titlecolor, $bodycolor);
    return $html ? "<span $tip>$text</span>" : $text;
}

#-------------------------------------------------------------------------------
#  Return a string for adding an onMouseover tooltip handler:
#
#     mouseover( $title, $text, $menu, $parent, $titlecolor, $bodycolor)
#
#  The code here is virtually identical to that in FIGjs.pm, but makes this
#  SEED independent.
#-------------------------------------------------------------------------------
sub mouseover
{
    # if ( $have_FIGjs ) { return &FIGjs::mouseover( @_ ) }

    my ( $title, $text, $menu, $parent, $titlecolor, $bodycolor ) = @_;

    defined( $title ) or $title = '';
    $title =~ s/'/\\'/g;    # escape '
    $title =~ s/"/&quot;/g; # escape "

    defined( $text ) or $text = '';
    $text =~ s/'/\\'/g;    # escape '
    $text =~ s/"/&quot;/g; # escape "

    defined( $menu ) or $menu = '';
    $menu =~ s/'/\\'/g;    # escape '
    $menu =~ s/"/&quot;/g; # escape "

    $parent     = '' if ! defined $parent;
    $titlecolor = '' if ! defined $titlecolor;
    $bodycolor  = '' if ! defined $bodycolor;

    qq( onMouseover="javascript:if(!this.tooltip) this.tooltip=new Popup_Tooltip(this,'$title','$text','$menu','$parent','$titlecolor','$bodycolor');this.tooltip.addHandler(); return false;" );
}

sub span_css {
    my ($text, $class) = @_;
    return $class ? "<span class=\"$class\">$text</span>" : $text;
}

1;

