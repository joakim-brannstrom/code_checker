/**
 * Authors: ponce
 * Date: July 28, 2014
 * License: Licensed under the MIT license. See LICENSE for more information
 * Version: 1.0.2
 */
module colorize;

public import colorize.colors;

/**
 * An enum listing possible colors for terminal output, useful to set the color
 * of a tag. Re-exported from d-colorize in dub.internal.colorize. See the enum
 * definition there for a list of possible values.
*/
alias Color = fg;
alias Background = bg;

/**
 * An enum listing possible text "modes" for terminal output, useful to set
 * the text to bold, underline, blinking, etc...
 * Re-exported from d-colorize in dub.internal.colorize. See the enum
 * definition there for a list of possible values.
*/
alias Mode = mode;
