//
//  HFRepresenterHexTextView.m
//  HexFiend_2
//
//  Created by Peter Ammon on 11/3/07.
//  Copyright 2007 __MyCompanyName__. All rights reserved.
//

#import <HexFiend/HFRepresenterHexTextView.h>
#import <HexFiend/HFRepresenterTextView_Internal.h>
#import <HexFiend/HFRepresenter.h>

@implementation HFRepresenterHexTextView

- (void)generateGlyphTable {
    /* Ligature generation is context dependent.  Rather than trying to parse the font tables ourselves, we make an NSTextView and stick it in a window, and then ask it to generate the glyphs for the hex representation of all 256 possible bytes.  Note that for this to work, the text view must be told to redisplay and it must be sufficiently wide so that it does not try to break the two-character hex across lines. */

    /* It is not strictly necessary to put the text view in a window.  But if NSView were to ever optimize setNeedsDisplay: to check for a nil window (it does not), then our crazy hack for generating ligatures might fail. */
    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
    [textView useAllLigatures:nil];
    NSFont *font = [[self font] screenFont];
    [textView setFont:font];

    /* We'll calculate the max glyph advancement as we go.  If this is a bottleneck, we can use the bulk getAdvancements:... method */
    glyphAdvancement = 0;

    NSUInteger nybbleValue, byteValue;
    for (nybbleValue=0; nybbleValue <= 0xF; nybbleValue++) {
        NSString *string;
        CGGlyph glyphs[GLYPH_BUFFER_SIZE];
        NSUInteger glyphCount;
        string = [[NSString alloc] initWithFormat:@"%lX", nybbleValue];
        glyphCount = [self _glyphsForString:string withGeneratingTextView:textView glyphs:glyphs];
        [string release];
        HFASSERT(glyphCount == 1); //How should I handle multiple glyphs for characters in [0-9A-Z]?  Are there any fonts that have them?  Doesn't seem likely.
        glyphTable[nybbleValue] = glyphs[0];
        glyphAdvancement = HFMax(glyphAdvancement, [font advancementForGlyph:glyphs[0]].width);
    }
    
    /* As far as I know, there are no ligatures for any of the byte values.  But we try to do it anyways. */
    bzero(ligatureTable, sizeof ligatureTable);
    for (byteValue=0; byteValue <= 0xFF; byteValue++) {
        NSString *string;
        CGGlyph glyphs[GLYPH_BUFFER_SIZE];
        NSUInteger glyphCount;
        string = [[NSString alloc] initWithFormat:@"%02lX", byteValue];
        glyphCount = [self _glyphsForString:string withGeneratingTextView:textView glyphs:glyphs];
        [string release];
        if (glyphCount == 1) {
            ligatureTable[byteValue] = glyphs[0];
            glyphAdvancement = HFMax(glyphAdvancement, [font advancementForGlyph:glyphs[0]].width);
        }
    }

#ifndef NDEBUG
    {
        CGGlyph glyphs[GLYPH_BUFFER_SIZE];
        [textView setFont:[NSFont fontWithName:@"Monaco" size:(CGFloat)10.]];
        [textView useAllLigatures:nil];
        HFASSERT([self _glyphsForString:@"fire" withGeneratingTextView:textView glyphs:glyphs] == 3); //fi ligature
        HFASSERT([self _glyphsForString:@"forty" withGeneratingTextView:textView glyphs:glyphs] == 5); //no ligatures
        HFASSERT([self _glyphsForString:@"flip" withGeneratingTextView:textView glyphs:glyphs] == 3); //fl ligature
    }
#endif
    

    [textView release];
    
    spaceAdvancement = glyphAdvancement;
}

- (void)setFont:(NSFont *)font {
    [super setFont:font];
    [self generateGlyphTable];
}

/* glyphs must have size at least 2 * numBytes */
- (void)extractGlyphsForBytes:(const unsigned char *)bytes count:(NSUInteger)numBytes intoArray:(CGGlyph *)glyphs resultingGlyphCount:(NSUInteger *)resultGlyphCount {
    HFASSERT(bytes != NULL);
    HFASSERT(glyphs != NULL);
    HFASSERT(numBytes <= NSUIntegerMax);
    HFASSERT(resultGlyphCount != NULL);
    NSUInteger glyphIndex = 0, byteIndex = 0;
    while (byteIndex < numBytes) {
        unsigned char byte = bytes[byteIndex++];
        if (ligatureTable[byte] != 0) {
            glyphs[glyphIndex++] = ligatureTable[byte];
            NSLog(@"Ligature for %u", byte);
        }
        else {
            glyphs[glyphIndex++] = glyphTable[byte >> 4];
            glyphs[glyphIndex++] = glyphTable[byte & 0xF];
        }
    }
    *resultGlyphCount = glyphIndex;
}

- (CGFloat)spaceBetweenBytes {
    return spaceAdvancement;
}

- (CGFloat)advancePerByte {
    return 2 * glyphAdvancement;
}

- (void)drawGlyphs:(CGGlyph *)glyphs count:(NSUInteger)glyphCount {
    HFASSERT(glyphs != NULL);
    HFASSERT(glyphCount > 0);
    HFASSERT((glyphCount & 1) == 0); //we should only ever be asked to draw an even number of glyphs
    CGContextRef ctx = [[NSGraphicsContext currentContext] graphicsPort];
    
    NEW_ARRAY(CGSize, advances, glyphCount);
    for (NSUInteger advanceIndex = 0; advanceIndex < glyphCount; advanceIndex++) {
        CGFloat horizontalAdvance;
        if (advanceIndex & 1) horizontalAdvance = spaceAdvancement + glyphAdvancement;
        else horizontalAdvance = glyphAdvancement;
        advances[advanceIndex] = CGSizeMake(horizontalAdvance, 0);
    }
    
    CGContextShowGlyphsWithAdvances(ctx, glyphs, advances, glyphCount);
    
    FREE_ARRAY(advances);
}


- (void)drawTextWithClip:(NSRect)clip {
    CGContextRef ctx = [[NSGraphicsContext currentContext] graphicsPort];
    NSRect bounds = [self bounds];
    CGFloat lineHeight = [self lineHeight];

    CGAffineTransform textTransform = CGContextGetTextMatrix(ctx);
    CGContextSetTextDrawingMode(ctx, kCGTextFill);

    NSUInteger byteIndex, bytesPerLine = [self bytesPerLine];
    NSData *data = [self data];
    NSUInteger byteCount = [data length];

    NSFont *font = [[self font] screenFont];
    const unsigned char *bytePtr = [data bytes];

    NSRect lineRectInBoundsSpace = NSMakeRect(NSMinX(bounds), NSMinY(bounds), NSWidth(bounds), lineHeight);
    lineRectInBoundsSpace.origin.y -= [self verticalOffset] * lineHeight;

    /* Start us off with the horizontal inset and move the baseline down by the ascender so our glyphs just graze the top of our view */
    textTransform.tx += [self horizontalContainerInset];
    textTransform.ty += [font ascender] - lineHeight * [self verticalOffset];
    NSUInteger lineIndex = 0;
    NEW_ARRAY(CGGlyph, glyphs, bytesPerLine*2);
    for (byteIndex = 0; byteIndex < byteCount; byteIndex += bytesPerLine) {
        if (byteIndex > 0) {
            textTransform.ty += lineHeight;
            lineRectInBoundsSpace.origin.y += lineHeight;
        }
        if (NSIntersectsRect(lineRectInBoundsSpace, clip)) {
            NSUInteger numBytes = MIN(bytesPerLine, byteCount - byteIndex);
            NSUInteger resultGlyphCount = 0;
            [self extractGlyphsForBytes:bytePtr + byteIndex count:numBytes intoArray:glyphs resultingGlyphCount:&resultGlyphCount];
            HFASSERT(resultGlyphCount > 0);
            CGContextSetTextMatrix(ctx, textTransform);
            [self drawGlyphs:glyphs count:resultGlyphCount];
        }
        else if (NSMinY(lineRectInBoundsSpace) > NSMaxY(clip)) {
            break;
        }
        lineIndex++;
    }
    FREE_ARRAY(glyphs);
}

- (NSRect)caretRect {
    NSRect result = [super caretRect];
    result.origin.x -= spaceAdvancement / 2;
    return result;
}

@end