VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
  Persistable = 0  'NotPersistable
  DataBindingBehavior = 0  'vbNone
  DataSourceBehavior  = 0  'vbNone
  MTSTransactionMode  = 0  'NotAnMTSObject
END
Attribute VB_Name = "pdGlyphCollection"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon Glyph Collection Interface
'Copyright 2015-2015 by Tanner Helland
'Created: 27/April/15
'Last updated: 27/April/15
'Last update: initial build
'Dependencies: pdGraphicsPath (for storing GDI+ path data after translating glyphs from TrueType or OpenType format)
'
'This class is currently under heavy construction.
'
'The goal of this class is to manage the creation and storage of individual text glyphs.  These glyphs are used by PD's text tool
' (and its corresponding class, pdTextRenderer) to enable advanced text features.
'
'Still TODO:
' - Enable hinting control via toggling GGO_UNHINTED.  (Right now, unhinted glyphs are explicitly specified.)
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'Copy of the GDI font handle used for glyph generation.
' IMPORTANT NOTE!  This class will select the font handle into a DC of its own creation.  Prior to passing this font handle
'                   to this class, you *must unselect it from any active DCs*.
Private m_GDIFont As Long

Private Type POINT_WIN32
    x As Long
    y As Long
End Type

Private Type POINT_FLOAT
    x As Single
    y As Single
End Type

'TrueType fonts use their own special fraction format.  Yes, it's obnoxious.
Private Type TT_FIXED
    Fract As Integer
    IntValue As Integer
End Type

'The fractional component of FIXED values are converted by dividing by 65536
Private Const FIXED_CONVERSION As Long = 65536

'The MAT2 type consists of 4 FIXED values (16-bits of fraction (unsigned), followed by 16-bits of integer (signed)) that comprise the
' four top-left spots of a 3x3.  We do actually use this matrix to reorient characters against their top-left corner.
Private Type MAT2
    eM11 As TT_FIXED
    eM12 As TT_FIXED
    eM21 As TT_FIXED
    eM22 As TT_FIXED
End Type

'Supported shape types inside TrueType and OpenType fonts
Private Const TT_PRIM_LINE As Long = 1       'Line or polyline primitive
Private Const TT_PRIM_QSPLINE As Long = 2    'Quadratic B�zier spline
Private Const TT_PRIM_CSPLINE As Long = 3    'Cubic B�zier spline

'Universal identifier of the TTPOLYGONHEADER struct
Private Const TT_POLYGON_TYPE As Long = 24

'This GLYPHMETRICS struct is passed to GetGlyphOutline; it contains basic positioning data, separate from the glyph itself.
' Note that all measurements are in *device units*.
Private Type GLYPHMETRICS
    gmBlackBoxX As Long    'Width and height of the smallest rectangle that completely encloses the glyph (its "black box").
    gmBlackBoxY As Long
    gmptGlyphOrigin As POINT_WIN32  '(X, Y) coordinates of the upper left corner of the smallest rectangle that completely encloses the glyph.
    gmCellIncX As Integer   'Horizontal and vertical distance from the origin of the current character cell to the origin of the next character cell.
    gmCellIncY As Integer   'IMPORTANT NOTE!  These values do not include kerning.  (How could they, when they're generated for a standalone glyph?)
End Type

'Generic GDI object management
Private m_oldFontHandle As Long
Private Declare Function SelectObject Lib "gdi32" (ByVal hDC As Long, ByVal hObject As Long) As Long
Private Declare Function DeleteObject Lib "gdi32" (ByVal hObject As Long) As Long

'If a glyph doesn't exist because a character is a whitespace character (fairly common case), retrieve a default width in its place.
Private Declare Function GetCharWidthFloat Lib "gdi32" Alias "GetCharWidthFloatW" (ByVal hDC As Long, ByVal iFirstChar As Long, ByVal repeatIFirstChar As Long, ByRef dstSingle As Single) As Long

'Glyph retrieval.  Per MSDN (https://msdn.microsoft.com/en-us/library/dd144891%28v=vs.85%29.aspx) I don't think there's any
' difference between the A and W variants, but W is declared for consistency with the rest of PD.
Private Const GGO_METRICS As Long = 0
Private Const GGO_NATIVE As Long = 2
Private Const GGO_BEZIER As Long = 3
Private Const GGO_UNHINTED As Long = &H100
Private Const GDI_ERROR As Long = &HFFFF
Private Declare Function GetGlyphOutline Lib "gdi32" Alias "GetGlyphOutlineW" (ByVal hDC As Long, ByVal uChar As Long, ByVal uFormat As Long, ByRef lpgm As GLYPHMETRICS, ByVal cbBuffer As Long, ByVal ptrToBuffer As Long, ByRef lpmat2 As MAT2) As Long

'This type is the minimum amount of data required to properly store and render a given glyph.  The pdGraphicsPath instance
' will be filled with a corresponding GDI+ GraphicsPath, assuming translation was successful.
Private Type pdGlyph
    charCode As Long                'Unicode entry point of this glyph
    gMetrics As GLYPHMETRICS        'Copy of the GLYPHMETRICS struct returned by GetGlyphMetrics
    glyphPath As pdGraphicsPath     'GDI+ GraphicsPath wrapper containing the fully translated font outline
    charIsWhiteSpace As Boolean     'If this character has no drawable glyph (e.g. " "), this will be set to TRUE.
    whiteSpaceWidth As Single       'For whitespace characters, we must retrieve their width using other means (as the glyph isn't helpful!)
End Type

'Current glyph collection.  Because glyph generation is very expensive, we store glyphs as we translate them.  If the font
' doesn't change, we can reuse glyphs from past calculations.
Private m_GlyphCollection() As pdGlyph

'Current number of generated glyphs.  This does not correspond to the UBound() of the glyph collection.
Private m_NumOfGlyphs As Long
Private Const INITIAL_GLYPH_COLLECTION_SIZE As Long = 128

'Generic identity matrix, as required by GetGlyphOutline
Private m_IdentityMatrix As MAT2

'Tiny temporary DIB, created once and cached; the target font is selected into this DIB prior to retrieving glyph outlines.
Private m_tmpDIB As pdDIB

'Metrics for the current font.  These are crucial because font path coordinate are all relative to the font baseline, but when rendering
' the path to the screen, we need to orient the points against the top-left corner of the image.  It's faster to apply this coordinate
' conversion when we first build the glyphs.
Private m_TextMetrics As TEXTMETRIC

'During glyph parsing, we have to apply a number of fixed conversions due to differences between TrueType coordinates and traditional
' screen coordinates.  We cache these values so we don't have to constantly retrieve them from the larger TEXTMETRIC struct.
Private m_FontAscent As Long, m_FontDescent As Long, m_FontHeight As Long

'Prior to glyph generation, this class needs a copy of GDI font handle.  I have deliberately made this function separate
' AS A REMINDER TO REMOVE THE FONT FROM ANY ACTIVE DCs PRIOR TO GIVING THIS CLASS ACCESS.
Public Sub notifyOfGDIFontChoice(ByVal srcGDIFontHandle As Long)

    'If this font matches previous font requests, we can retain existing glyph information.
    
    'If it doesn't match, we need to start over from scratch.  Alas.
    If m_GDIFont <> srcGDIFontHandle Then
        
        'Wipe the current glyph collection
        resetGlyphCollection
        
        'Copy the font handle
        m_GDIFont = srcGDIFontHandle
        
    End If
    
    'Select the font into our temporary DC.  (Many GDI functions operate on DCs instead of hFonts, so this is important.)
    m_oldFontHandle = SelectObject(m_tmpDIB.getDIBDC, m_GDIFont)
    
    'Retrieve text metrics for this font, and cache any metrics required on the inner glyph parsing loop
    Font_Management.fillTextMetrics m_tmpDIB.getDIBDC, m_TextMetrics
    m_FontAscent = m_TextMetrics.tmAscent
    m_FontDescent = m_TextMetrics.tmDescent
    m_FontHeight = m_TextMetrics.tmHeight
    
End Sub

'After this class has done its work, the caller MUST CALL THIS FUNCTION to release their font from our internal DC
Public Sub requestGDIFontRelease()
    SelectObject m_tmpDIB.getDIBDC, m_oldFontHandle
End Sub

'Given a source string, add all glyphs from that string to our current collection
Public Function buildGlyphCollection(ByRef srcString As String, Optional ByVal useHinting As Boolean = False) As Boolean
    
    Dim curChar As Long
    Dim charAlreadyExists As Boolean
    Dim rawGlyphBytes() As Long
    Dim glyphAdded As Boolean
    
    'Start iterating through the string, one character at a time.
    Dim i As Long, j As Long
    For i = 0 To Len(srcString) - 1
        
        charAlreadyExists = False
        glyphAdded = False
        
        'Retrieve the current character code
        curChar = AscW(Mid$(srcString, i + 1, 1))
        
        'See if the code already exists in our collection
        If m_NumOfGlyphs > 0 Then
            
            For j = 0 To m_NumOfGlyphs - 1
                
                'If this glyph already exists, mark it and exit immediately
                If curChar = m_GlyphCollection(j).charCode Then
                    charAlreadyExists = True
                    Exit For
                End If
                
            Next j
            
        End If
        
        'If the current character isn't in our collection, retrieve it now
        If (Not charAlreadyExists) Then
            
            'Store this character code
            m_GlyphCollection(m_NumOfGlyphs).charCode = curChar
            
            'Start by retrieving the raw glyph buffer.
            If getRawGlyphBuffer(curChar, rawGlyphBytes, useHinting) Then
                
                'With the raw buffer retrieved, we can now walk the byte array and retrieve individual line and curve metrics.
                
                'Before doing that, see if the buffer size is non-zero.  This is valid output for whitespace characters (e.g. spaces).
                If UBound(rawGlyphBytes) > 0 Then
                    
                    'Debug.Print ChrW$(curChar) & ":" & UBound(rawGlyphBytes)
                    
                    'Proceed with parsing this glyph
                    If parseRawGlyphBuffer(rawGlyphBytes, m_GlyphCollection(m_NumOfGlyphs).glyphPath) Then
                        
                        'Some missing glyphs are supplied with a box shape.  Check for a few obvious ones and replace them now.
                        If curChar = AscW(vbLf) Then
                            m_GlyphCollection(m_NumOfGlyphs).charIsWhiteSpace = True
                        Else
                        
                            'Clear the whitespace flag and note that this glyph is valid.
                            m_GlyphCollection(m_NumOfGlyphs).charIsWhiteSpace = False
                            
                            'Want to see this character's GLYPHMETRICS struct?  Uncomment the block below
                            'With m_GlyphCollection(m_NumOfGlyphs).gMetrics
                            '    Debug.Print "CHAR: " & ChrW$(curChar) & ", " & .gmBlackBoxX & ", " & .gmBlackBoxY & ", " & .gmCellIncX & ", " & .gmCellIncY & ", " & .gmptGlyphOrigin.x & ", " & .gmptGlyphOrigin.y
                            'End With
                            
                        End If
                        
                        'Note that this glyph is valid; this will move the collection pointer to the next entry in the stack
                        glyphAdded = True
                        
                    'Glyph buffer parsing failed
                    Else
                        #If DEBUGMODE = 1 Then
                            pdDebug.LogAction "WARNING!  parseRawGlyphBuffer failed for character code " & curChar
                        #End If
                        
                        glyphAdded = False
                        
                    End If
                
                'This is likely a whitespace character.
                Else
                    
                    'Debug.Print "FAILURE: " & ChrW$(curChar) & ":" & UBound(rawGlyphBytes)
                    
                    'Mark the whitespace flag, retrieve a default width, and note that this glyph is valid.
                    m_GlyphCollection(m_NumOfGlyphs).charIsWhiteSpace = True
                    m_GlyphCollection(m_NumOfGlyphs).whiteSpaceWidth = m_TextMetrics.tmAveCharWidth
                    glyphAdded = True
                
                End If
            
            'Raw glyph buffer retrieval failed.  This is a valid return for some whitespace characters.
            Else
                
                'Mark the whitespace flag, retrieve a default width, and note that this glyph is valid.
                m_GlyphCollection(m_NumOfGlyphs).charIsWhiteSpace = True
                m_GlyphCollection(m_NumOfGlyphs).whiteSpaceWidth = getWidthOfCharCode(curChar)
                glyphAdded = True
                
            End If
            
            'If a glyph was successfully added to the collection, increment the current glyph count and resize the collection as necessary.
            If glyphAdded Then
                m_NumOfGlyphs = m_NumOfGlyphs + 1
                If m_NumOfGlyphs > UBound(m_GlyphCollection) Then ReDim Preserve m_GlyphCollection(0 To m_NumOfGlyphs * 2 - 1) As pdGlyph
            End If
            
        '(End "If Not charAlreadyExists")
        End If
        
    Next i
    
    'Before exiting, remove the active font into our temporary "testing" DC
    SelectObject m_tmpDIB.getDIBDC, m_oldFontHandle

End Function

'Given a Unicode entry point, fill a buffer with the raw output of GetGlyphOutline
Private Function getRawGlyphBuffer(ByVal curChar As Long, ByRef dstBuffer() As Long, Optional ByVal useHinting As Boolean = False) As Boolean
    
    'We could start by retrieving glyph metrics, which are plugged directly into the current glyph entry in the master collection.
    ' (These metrics are separate from the glyph shape; we use them to control inter-character spacing, among other things.)
    
    'To grab these, use the following line of code:
    'ggoReturn = GetGlyphOutline(m_tmpDIB.getDIBDC, curChar, GGO_METRICS, m_GlyphCollection(m_NumOfGlyphs).gMetrics, 0, 0, m_IdentityMatrix)
    
    'The reason I don't do this is that the metrics will be retrieved anyway by our next call, which requests length of the raw
    ' glyph buffer.  For performance reasons, we kill two birds with one stone on that call.
    
    'Prior to retrieving metrics, set the hinting flag.  Note that hinting is optional, and its presence (or lack thereof)
    ' has consequences for glyph shape and positioning.
    Dim formatFlags As Long
    formatFlags = GGO_BEZIER
    If (Not useHinting) Then formatFlags = formatFlags Or GGO_UNHINTED
    
    'Next, we want to retrieve the required size of the glyph shape buffer.  FYI, for complex glyphs, this can be fairly large.
    ' Note also that we explicitly request bezier curve format.  This makes our subsequent parsing much easier, and improves the
    ' output fidelity of OpenType fonts.
    Dim ggoReturn As Long, byteSizeOfBuffer As Long
    ggoReturn = GetGlyphOutline(m_tmpDIB.getDIBDC, curChar, formatFlags, m_GlyphCollection(m_NumOfGlyphs).gMetrics, 0, 0, m_IdentityMatrix)
    
    'ggoReturn should be > 0, which tells us the required size of the destination buffer.
    If ggoReturn <= 0 Then
        
        'If zero is returned, that's okay; this might just be a whitespace character with no corresponding glyph.
        ' Return TRUE; the caller function has logic to deal with this combination of outputs.
        ReDim dstBuffer(0) As Long
        getRawGlyphBuffer = True
        Exit Function
    
    Else
        
        'Note the required buffer size
        byteSizeOfBuffer = ggoReturn
        
    End If
    
    'Prep the buffer.  For convenience, we've declared the buffer as type LONG to prevent us having to do too much
    ' manual parsing.  This size strategy requires us to divide the byte size of the buffer by 4 (obviously).
    ReDim dstBuffer(0 To (byteSizeOfBuffer \ 4) - 1) As Long
    
    'Now we can retrieve the actual data buffer!
    ggoReturn = GetGlyphOutline(m_tmpDIB.getDIBDC, curChar, formatFlags, m_GlyphCollection(m_NumOfGlyphs).gMetrics, byteSizeOfBuffer, VarPtr(dstBuffer(0)), m_IdentityMatrix)
    
    'Per MSDN, successful queries return a value > 0
    getRawGlyphBuffer = CBool(ggoReturn > 0)
    
End Function

'Given the raw byte stream returned by GetGlyphOutline, walk the buffer and assemble a matching GDI+ Graphics Path from the output.
Private Function parseRawGlyphBuffer(ByRef srcBuffer() As Long, ByRef dstGlyphPath As pdGraphicsPath) As Boolean
    
    'Parsing the output of GetGlyphOutline isn't quite as nasty as you'd thing.  The structs themselves are actually
    ' pretty straightforward; it's the asinine data types used that make things unpleasant.
    
    'This MSDN article provides an incredibly helpful overview.  (That might be the first time I've ever said such a thing.)
    ' https://support.microsoft.com/en-us/kb/243285
    
    'First, you need to understand a few crucial structs.  We don't actually declare these structs (because copying data to/from them
    ' is a giant waste of time when we can just read the bytes directly).  These structs are:
    
    'Type POINTFX
    '    FIXED x
    '    FIXED y
    'End Type
    
    'Remember that FIXED is a 4-byte type with 2 bytes of unsigned fraction ( / 65536), followed by 2 bytes of signed integer.
    ' From the relevant Dr Dobbs article (http://www.drdobbs.com/truetype-font-secrets/184403680):
    ' "Value represents the part of the real number to the left of the decimal point; fract represents the part to the right of the
    '  decimal point, considered as a fraction of 65,536. For example, 0.5 becomes (fract, value) = (32768, 0); 2.25 is equivalent
    '  to (fract, value) = (16384, 2)."
    
    'Type TTPOLYGONHEADER
    '    cb As Long            'Bytes required by the TTPOLYGONHEADER structure and any TTPOLYCURVE structure(s) that follow it.
    '    dwType As Long        'Always the TT_POLYGON_TYPE constant, so we can happily ignore it
    '    pfxStart As POINTFX   'Starting point of the contour in the character outline.
    'End Type
    
    'Each TTPOLYGONHEADER is followed by one or more TTPOLYCURVE structs.  The number of structs can't be inferred in advance,
    ' because curve size varies according to complexity.
    
    'Type TTPOLYCURVE
    '    wType As Integer    'Type of the curve.  This can be one of three values; see below
    '    cpfx As Integer     'The number of POINTFX structures in this curve (e.g. the size of the curve array, if you want to approach it that way)
    '    apfx() As POINTFX   'Array of POINTFX structures, with number of entries = cpfx
    'End Type
    
    'TTPOLYCURVES take three forms, as marked by wType:
    ' 1) Line and/or polyline primitives (TT_PRIM_LINE)
    ' 2) Quadratic B�zier splines (TT_PRIM_QSPLINE).  This is the default curve format for TrueType fonts.
    ' 3) Cubic B�zier splines (TT_PRIM_CSPLINE).  This is the default curve format for OpenType fonts, but to get this format,
    '                                              we have to explicitly specify the GGO_BEZIER flag.  (PD does exactly this,
    '                                              to preserve better OpenType glyph shaping.)
    
    'These structs are all fairly straightforward; the biggest hit is converting the damn POINTFX structs into usable Single-type values.

    'The raw byte stream handed to us by GetGlyphOutline can be read as follows:
    ' 1) A glyph outline is returned as a series of one or more contours defined by a TTPOLYGONHEADER structure followed by one or more curves.
    ' 2) Each curve in the contour is defined by a TTPOLYCURVE structure followed by a number of POINTFX data points.
    ' 3) POINTFX points are absolute positions, not relative moves.  (This is awesome, actually, as it makes GDI+ conversion *much* easier)
    ' 4) The starting point of a contour is given by the pfxStart member of the TTPOLYGONHEADER structure.
    ' 5) The starting point of each curve is the last point of the previous curve or the starting point of the contour.
    ' 6) The count of data points in a curve is stored in the cpfx member of TTPOLYCURVE structure.
    ' 7) The size of each contour in the buffer, in bytes, is stored in the cb member of TTPOLYGONHEADER structure.
    ' 8) Additional curve definitions are packed into the buffer following preceding curves, and additional contours are packed into
    '    the buffer following preceding contours.
    ' 9) The buffer contains as many contours as fit within the buffer returned by GetGlyphOutline.
    
    'This seems like a lot of caveats, but honestly, it's not too bad to walk the struct like this.  Let's begin!
    
    'Start by initializing the destination graphics path
    Set dstGlyphPath = New pdGraphicsPath
    
    Dim firstPoint As POINT_FLOAT, prevPoint As POINT_FLOAT, nextPoint As POINT_FLOAT
    Dim bezPoint2 As POINT_FLOAT, bezPoint3 As POINT_FLOAT
    Dim curveType As Long, pointCount As Long
    Dim i As Long
    
    Dim curPosition As Long
    curPosition = 0
    
    Dim endOfCurrentCurve As Long
    endOfCurrentCurve = 0
    
    Do
        
        'Start by parsing this TTPOLYGONHEADER, which defines a single contiguous shape.
        
        'Type TTPOLYGONHEADER
        '    cb As Long            'Bytes required by this TTPOLYGONHEADER structure and any structure(s) that follow it.
        '    dwType As Long        'Always the TT_POLYGON_TYPE constant, so we can happily ignore it
        '    pfxStart As POINTFX   'Starting point of this contour in the character outline.
        'End Type
        
        'Technically, we could start this task by double-checking the required TTPOLYGONHEADER.dwType value, which should always be
        ' TT_POLYGON_TYPE... but since it never deviates, let's just ignore it.  (FYI it would occur at position "curPosition + 1")
        
        'First things first: retrieve the ending position of this struct.  We'll use this to know when to close the current curve.
        ' (Remember that buffer sizes are in bytes, but our array is Long-type.)
        endOfCurrentCurve = curPosition + srcBuffer(curPosition) \ 4
        
        'Next, retrieve the first point in the glyph.  Note that this point is relative to the origin of the glyph, and the origin
        ' of a glyph is *always* the lower left corner of the character at the character's baseline.
        firstPoint.x = getSingleFromFIXED(srcBuffer(curPosition + 2))
        firstPoint.y = getSingleFromFIXED(srcBuffer(curPosition + 3))
        
        'Also note the first point as the "previous point"; this simplifies our calculations on the inner loop
        prevPoint.x = firstPoint.x
        prevPoint.y = firstPoint.y
        
        'Advance the buffer pointer
        curPosition = curPosition + 4
        
        'With the first point determined, we can now proceed with parsing the next shape in line.
        Do
        
            'Next, we parse a TT_POLYCURVE struct, which looks like this:
            
            'Type TTPOLYCURVE
            '    wType As Integer    'Type of the curve.  This can be one of three values; see below
            '    cpfx As Integer     'The number of POINTFX structures in this curve (e.g. the UBound of the curve array, if you want to approach it that way)
            '    apfx() As POINTFX   'Array of POINTFX structures, with number of entries = cpfx
            'End Type
            
            'Start by retrieving the curve type and number of points in this curve
            curveType = srcBuffer(curPosition) And 65535
            pointCount = srcBuffer(curPosition) \ 65536
            
            'Advance the pointer to the start of the POINTFX array
            curPosition = curPosition + 1
            
            Select Case curveType
            
                'Polyline
                Case TT_PRIM_LINE
                
                    'Polylines are easiest: just iterate each line, adding segments as we go
                    For i = 1 To pointCount
                        
                        'Add this line segment
                        nextPoint.x = getSingleFromFIXED(srcBuffer(curPosition))
                        nextPoint.y = getSingleFromFIXED(srcBuffer(curPosition + 1))
                        dstGlyphPath.addLine prevPoint.x, prevPoint.y, nextPoint.x, nextPoint.y
                        
                        'Copy the next point into the previous point marker
                        prevPoint = nextPoint
                        
                        'Advance to the next buffer position
                        curPosition = curPosition + 2
                        
                    Next i
                
                'Quadratic B�zier spline (PD doesn't currently handle this case, because we explicitly request cubic bezier splines
                ' from the font mapper).
                'Case TT_PRIM_QSPLINE
                
                'Cubic B�zier spline
                Case TT_PRIM_CSPLINE
                    
                    'Cubic splines occur in sets of four points (but one is already known from the end of the previous curve)
                    ' Iterate each in turn.
                    For i = 1 To pointCount Step 3
                    
                        'Previous point is already known; retrieve the next three points explicitly
                        bezPoint2.x = getSingleFromFIXED(srcBuffer(curPosition))
                        bezPoint2.y = getSingleFromFIXED(srcBuffer(curPosition + 1))
                        
                        bezPoint3.x = getSingleFromFIXED(srcBuffer(curPosition + 2))
                        bezPoint3.y = getSingleFromFIXED(srcBuffer(curPosition + 3))
                        
                        nextPoint.x = getSingleFromFIXED(srcBuffer(curPosition + 4))
                        nextPoint.y = getSingleFromFIXED(srcBuffer(curPosition + 5))
                        
                        dstGlyphPath.addBezierCurve prevPoint.x, prevPoint.y, bezPoint2.x, bezPoint2.y, bezPoint3.x, bezPoint3.y, nextPoint.x, nextPoint.y
                        
                        'Copy the next point into the previous point marker
                        prevPoint = nextPoint
                        
                        'Advance to the next buffer position
                        curPosition = curPosition + 6
                    
                    Next i
            
            End Select
        
        'If there are more lines and/or curves in this shape, continue on with the next one
        Loop Until curPosition >= endOfCurrentCurve
    
        'This shape is now complete.  Close the path.
        dstGlyphPath.closeCurrentFigure
    
    'If more shapes exist, draw them next
    Loop Until curPosition >= UBound(srcBuffer)
    
    'With parsing complete, we now need to translate the finished glyph downward.  TrueType and OpenType fonts are positioned against
    ' relative to their baseline, so (0, 0) is the bottom-left point of the glyph that touches the baseline.  When rendering to the
    ' screen, we obviously want things oriented against their top-left corner.
    
    'We can do this by translating the path downward by the current font's ascender value, which is constant for all glyphs.
    dstGlyphPath.translatePath 0, m_FontAscent
    
    'Parsing complete!
    parseRawGlyphBuffer = True

End Function

'After assembling a full glyph collection, this function can be called to generate a totally complete graphics path, with all
' characters laid out according to the passed rect.
Friend Function assembleCompositePath(ByVal srcString As String, ByRef dstPath As pdGraphicsPath, ByRef boundingRect As RECTF) As Boolean
    
    'Initialize the destination path as necessary
    If dstPath Is Nothing Then Set dstPath = New pdGraphicsPath
    
    'Only proceed if the source string is non-empty
    If Len(srcString) <> 0 Then
        
        'Before processing the string, let's do some preprocessing to it.
        
        'First, normalize all linebreaks to vbLf
        If InStr(1, srcString, vbCrLf, vbBinaryCompare) <> 0 Then srcString = Replace$(srcString, vbCrLf, vbLf)
        If InStr(1, srcString, vbCr, vbBinaryCompare) <> 0 Then srcString = Replace$(srcString, vbCr, vbLf)
        
        'Add more in the future, perhaps...?
        
        Dim i As Long, glyphIndex As Long, srcPathHandle As Long
        Dim xOffset As Single, yOffset As Single
        yOffset = 0
        xOffset = 0
        
        'Start iterating through the source string, one character at a time.
        For i = 0 To Len(srcString) - 1
            
            'Start by retrieving this glyph index
            glyphIndex = getGlyphIndex(AscW(Mid$(srcString, i + 1, 1)))
            
            If glyphIndex >= 0 Then
                
                'Retrieve a handle to this glyph's path.  If the handle is zero, there are two possible explanations:
                ' 1) The glyph is a whitespace character
                ' 2) The glyph couldn't be generated
                
                '(1) is common, and (2) should never happen.  Process accordingly.
                If m_GlyphCollection(glyphIndex).charIsWhiteSpace Then
                    
                    'Line feeds are a special case of white space.
                    If m_GlyphCollection(glyphIndex).charCode = AscW(vbLf) Then
                    
                        yOffset = yOffset + m_TextMetrics.tmHeight + m_TextMetrics.tmExternalLeading
                        xOffset = 0
                    
                    'For other whitespace chars, plug in a default space value
                    Else
                    
                        'Add the manually retrieved glyph width to the running offset
                        xOffset = xOffset + m_GlyphCollection(glyphIndex).whiteSpaceWidth
                        
                    End If
                    
                Else
                    
                    'See if this glyph extends past the end of the line.  If it does, push us down to the next line.
                    If xOffset + m_GlyphCollection(glyphIndex).gMetrics.gmCellIncX > boundingRect.Width Then
                        yOffset = yOffset + m_TextMetrics.tmHeight + m_TextMetrics.tmExternalLeading
                        xOffset = 0
                    End If
                    
                    'Add this glyph to the current path at the running x-offset
                    
                    'If this is the start of a line, look for characters that hang off the left side of the bounding box, and push them
                    ' in-bounds.
                    If xOffset = 0 Then
                        If m_GlyphCollection(glyphIndex).gMetrics.gmptGlyphOrigin.x < 0 Then xOffset = Abs(m_GlyphCollection(glyphIndex).gMetrics.gmptGlyphOrigin.x)
                    End If
                    
                    dstPath.addPath m_GlyphCollection(glyphIndex).glyphPath, xOffset, yOffset
                    
                    'Add the glyph's width to the running x-direction offset.
                    xOffset = xOffset + m_GlyphCollection(glyphIndex).gMetrics.gmCellIncX
                
                End If
                
            Else
                Debug.Print "for some reason, that glyph doesn't exist???"
            End If
            
        Next i
        
    End If
        
    assembleCompositePath = True

End Function

'Given a Long-type value - which is really a FIXED struct in disguise - parse out the two chunks, and return them as a normal floating-point value
Private Function getSingleFromFIXED(ByRef srcFixed As Long) As Single
    
    'TODO: investigate LSet for performance
    'Dim tmpFixed As TT_FIXED
    'LSet tmpFixed = srcFixed
    
    'First, retrieve the fraction portion of the Long (which is UNSIGNED)
    Dim fracPortion As Long, integerPortion As Integer
    integerPortion = ((srcFixed And &H7FFF0000) \ &H10000) Or (&H8000 And srcFixed < 0)
    
    'Next, retrieve the value portion of the Long (which is SIGNED)
    fracPortion = (srcFixed And &HFFFF&)
    
    'Finally, return these using the standard FIXED conversion
    getSingleFromFIXED = CDbl(integerPortion) + CDbl(fracPortion) / 65536#
    
End Function

'GetCharWidthFloat is an interesting function; I've included it here in case I ever decide to test it further.
Private Function getWidthOfCharCode(ByVal srcCharCode As Long) As Single
    GetCharWidthFloat m_tmpDIB.getDIBDC, srcCharCode, srcCharCode, getWidthOfCharCode
End Function

'Reset the current glyph collection.  This forces all glyphs to be recreated from scratch, so use only if absolutely necessary.
Private Sub resetGlyphCollection()
    
    'If the glyph collection exists, manually wipe it
    If m_NumOfGlyphs > 0 Then
        
        Dim i As Long
        For i = 0 To m_NumOfGlyphs - 1
            Set m_GlyphCollection(i).glyphPath = Nothing
        Next i
        
    End If
    
    'Resize the array to default values
    m_NumOfGlyphs = 0
    ReDim m_GlyphCollection(0 To INITIAL_GLYPH_COLLECTION_SIZE - 1) As pdGlyph
    
End Sub

'Return a copy of a path handle for an assembled glyph.  Returns 0 if no path data exists.  Note that 0 is valid output,
' as whitespace characters do not have glyphs (for most fonts, anyway).
Public Function getGlyphPathHandle(ByVal glyphIndex As Long) As Long
    
    If Not m_GlyphCollection(glyphIndex).glyphPath Is Nothing Then
        getGlyphPathHandle = m_GlyphCollection(glyphIndex).glyphPath.getCopyOfPathHandle
    Else
        getGlyphPathHandle = 0
    End If
    
End Function

'Given a Unicode entry point, return the matching glyph index.  Returns -1 if the glyph is missing from the current collection.
Public Function getGlyphIndex(ByVal srcCharValue As Long) As Long
    
    'Start iterating through the glyph collection, looking for the matching value
    Dim i As Long
    For i = 0 To m_NumOfGlyphs - 1
    
        If srcCharValue = m_GlyphCollection(i).charCode Then
            getGlyphIndex = i
            Exit Function
        End If
    
    Next i
    
    'If we made it all the way here, the glyph does not exist.  Oops?
    getGlyphIndex = -1
    
End Function

Private Sub Class_Initialize()
    
    m_GDIFont = 0
    
    'Create an identity matrix and cache it at class level.  Note that we deliberately invert the y-value as glyphs are returned in a
    ' coordinate system relative to their baseline, where as screen coordinates are relative to the top-left.
    ' [1, 0]
    ' [0, 1]
    With m_IdentityMatrix
        .eM11.IntValue = 1
        .eM22.IntValue = -1
    End With
    
    'Create a temporary DIB for selecting the font into
    Set m_tmpDIB = New pdDIB
    m_tmpDIB.createBlank 4, 4
    
End Sub
