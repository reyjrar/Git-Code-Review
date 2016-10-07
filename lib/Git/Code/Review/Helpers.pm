package Git::Code::Review::Helpers;
use strict;
use warnings;

our $VERSION = 0.01;
use Exporter 'import';
our @EXPORT_OK = qw(
    paragraphs_to_string
    prompt_message
);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

use CLI::Helpers qw(
    debug
    debug_var
    output
    prompt
);


sub paragraphs_to_string {
    my ($paragraphs) = @_;
    my @content = $paragraphs ? map { ( "$_\n", "\n" ) } ref( $paragraphs ) eq 'ARRAY' ? @$paragraphs : ( $paragraphs ) : ();
    pop @content if scalar @content;    # remove the last empty line
    return join '', @content;
}

sub prompt_message {
    my ($prompt_message, $default_messages) = @_;
    my $message = paragraphs_to_string( $default_messages );
    return $message if length $message > 10;
    return prompt($prompt_message, validate => { "Please give 10+ characters or leave empty to abort" => sub { length $_ > 10 || length $_ == 0 } });
}


1;

__END__

=head1 NAME

Git::Code::Review::Helpers - helper functions useful for git code review

=head1 SYNOPSIS

use Git::Code::Review::Helpers;

=head1 DESCRIPTION

Helper functions useful for git code review

=head1 AUTHOR

Samit Badle

=head1 COPYRIGHT

(c) 2016 All rights reserved.

=cut
