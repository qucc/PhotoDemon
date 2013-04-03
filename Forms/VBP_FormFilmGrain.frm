VERSION 5.00
Begin VB.Form FormFilmGrain 
   BackColor       =   &H80000005&
   BorderStyle     =   4  'Fixed ToolWindow
   Caption         =   " Apply Film Grain"
   ClientHeight    =   6540
   ClientLeft      =   45
   ClientTop       =   285
   ClientWidth     =   12120
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   8.25
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   LinkTopic       =   "Form1"
   MaxButton       =   0   'False
   MinButton       =   0   'False
   ScaleHeight     =   436
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   808
   ShowInTaskbar   =   0   'False
   StartUpPosition =   1  'CenterOwner
   Begin VB.TextBox txtRadius 
      Alignment       =   2  'Center
      BeginProperty Font 
         Name            =   "Tahoma"
         Size            =   9.75
         Charset         =   0
         Weight          =   400
         Underline       =   0   'False
         Italic          =   0   'False
         Strikethrough   =   0   'False
      EndProperty
      ForeColor       =   &H00800000&
      Height          =   360
      Left            =   11160
      MaxLength       =   3
      TabIndex        =   8
      Text            =   "5"
      Top             =   3420
      Width           =   615
   End
   Begin VB.HScrollBar hsRadius 
      Height          =   255
      Left            =   6120
      Max             =   25
      Min             =   1
      TabIndex        =   7
      Top             =   3480
      Value           =   5
      Width           =   4935
   End
   Begin VB.CommandButton CmdOK 
      Caption         =   "&OK"
      Default         =   -1  'True
      Height          =   495
      Left            =   9135
      TabIndex        =   0
      Top             =   5910
      Width           =   1365
   End
   Begin VB.CommandButton CmdCancel 
      Cancel          =   -1  'True
      Caption         =   "&Cancel"
      Height          =   495
      Left            =   10605
      TabIndex        =   1
      Top             =   5910
      Width           =   1365
   End
   Begin VB.HScrollBar hsNoise 
      Height          =   255
      Left            =   6120
      Max             =   50
      Min             =   1
      TabIndex        =   3
      Top             =   2640
      Value           =   10
      Width           =   4935
   End
   Begin VB.TextBox txtNoise 
      Alignment       =   2  'Center
      BeginProperty Font 
         Name            =   "Tahoma"
         Size            =   9.75
         Charset         =   0
         Weight          =   400
         Underline       =   0   'False
         Italic          =   0   'False
         Strikethrough   =   0   'False
      EndProperty
      ForeColor       =   &H00800000&
      Height          =   360
      Left            =   11160
      MaxLength       =   3
      TabIndex        =   2
      Text            =   "10"
      Top             =   2580
      Width           =   615
   End
   Begin PhotoDemon.fxPreviewCtl fxPreview 
      Height          =   5625
      Left            =   120
      TabIndex        =   6
      Top             =   120
      Width           =   5625
      _ExtentX        =   9922
      _ExtentY        =   9922
   End
   Begin VB.Label lblTitle 
      AutoSize        =   -1  'True
      BackStyle       =   0  'Transparent
      Caption         =   "softness:"
      BeginProperty Font 
         Name            =   "Tahoma"
         Size            =   12
         Charset         =   0
         Weight          =   400
         Underline       =   0   'False
         Italic          =   0   'False
         Strikethrough   =   0   'False
      EndProperty
      ForeColor       =   &H00404040&
      Height          =   285
      Index           =   0
      Left            =   6000
      TabIndex        =   9
      Top             =   3120
      Width           =   945
   End
   Begin VB.Label lblBackground 
      Height          =   855
      Left            =   -120
      TabIndex        =   5
      Top             =   5760
      Width           =   12375
   End
   Begin VB.Label Label1 
      AutoSize        =   -1  'True
      BackStyle       =   0  'Transparent
      Caption         =   "strength:"
      BeginProperty Font 
         Name            =   "Tahoma"
         Size            =   12
         Charset         =   0
         Weight          =   400
         Underline       =   0   'False
         Italic          =   0   'False
         Strikethrough   =   0   'False
      EndProperty
      ForeColor       =   &H00404040&
      Height          =   285
      Left            =   6000
      TabIndex        =   4
      Top             =   2280
      Width           =   960
   End
End
Attribute VB_Name = "FormFilmGrain"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = False
'***************************************************************************
'Add Film Grain Tool
'Copyright �2012-2013 by Tanner Helland
'Created: 31/January/13
'Last updated: 31/January/13
'Last update: initial build
'
'Tool for simulating film grain.  For aesthetic reasons, film grain is restricted to monochromatic noise
' (luminance only) to better mimic traditional film grain.
'
'The separate standalone Gaussian Blur function is used for noise smoothing.
'
'***************************************************************************

Option Explicit

'When previewing, we need to modify the strength to be representative of the final filter.  This means dividing by the
' original image dimensions in order to establish the right ratio.
Dim iWidth As Long, iHeight As Long

'CANCEL button
Private Sub CmdCancel_Click()
    Unload Me
End Sub

'OK button
Private Sub cmdOK_Click()

    'Validate all text box entries
    If Not EntryValid(txtRadius, hsRadius.Min, hsRadius.Max, True, True) Then
        AutoSelectText txtRadius
        Exit Sub
    End If
    
    If Not EntryValid(txtNoise, hsNoise.Min, hsNoise.Max, True, True) Then
        AutoSelectText txtNoise
        Exit Sub
    End If
    
    Me.Visible = False
    Process FilmGrain, hsNoise.Value, hsRadius.Value
    Unload Me
    
End Sub

'Subroutine for adding noise to an image
' Inputs: Amount of noise, monochromatic or not, preview settings
Public Sub AddFilmGrain(ByVal gStrength As Double, ByVal gSoftness As Long, Optional ByVal toPreview As Boolean = False, Optional ByRef dstPic As fxPreviewCtl)
        
    If Not toPreview Then Message "Generating film grain texture..."
    
    'Create a local array and point it at the pixel data of the current image
    Dim dstSA As SAFEARRAY2D
    prepImageData dstSA, toPreview, dstPic
    
    'Create a separate source layer.  This will contain the a copy of the current image, and we will use it as our source reference
    ' (This is necessary to prevent adjusted pixel values from spreading across the image as we go.)
    Dim srcLayer As pdLayer
    Set srcLayer = New pdLayer
    srcLayer.createFromExistingLayer workingLayer
    
    'Create a layer to hold the gaussian blur
    Dim gaussLayer As pdLayer
    Set gaussLayer = New pdLayer
    
    'Create a layer to hold the film grain
    Dim noiseLayer As pdLayer
    Set noiseLayer = New pdLayer
    noiseLayer.createFromExistingLayer workingLayer
    
    'Local loop variables can be more efficiently cached by VB's compiler, so we transfer all relevant loop data here
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = curLayerValues.Left
    initY = curLayerValues.Top
    finalX = curLayerValues.Right
    finalY = curLayerValues.Bottom
    
    'Point an array at the noise layer
    Dim dstImageData() As Byte
    prepSafeArray dstSA, noiseLayer
    CopyMemory ByVal VarPtrArray(dstImageData()), VarPtr(dstSA), 4
    
    'These values will help us access locations in the array more quickly.
    ' (qvDepth is required because the image array may be 24 or 32 bits per pixel, and we want to handle both cases.)
    Dim QuickVal As Long, qvDepth As Long
    qvDepth = curLayerValues.BytesPerPixel
    
    'To keep processing quick, only update the progress bar when absolutely necessary.  This function calculates that value
    ' based on the size of the area to be processed.
    Dim progBarCheck As Long
    SetProgBarMax finalY * 2 + finalX * 2
    progBarCheck = findBestProgBarValue()
        
    'Noise variables
    Dim nColor As Long
    Dim gStrength2 As Long
    
    'Double the amount of noise we plan on using (so we can add noise above or below the current color value)
    gStrength2 = gStrength * 2
    
    'Although it's slow, we're stuck using random numbers for noise addition.  Seed the generator with a pseudo-random value.
    Randomize Timer
    
    'Loop through each pixel in the image, converting values as we go
    For x = initX To finalX
        QuickVal = x * qvDepth
    For y = initY To finalY
                    
        'Generate monochromatic noise, e.g. the same amount of noise for each color component, based around RGB(127, 127, 127)
        nColor = 127 + (gStrength2 * Rnd) - gStrength
        
        'Assign that noise to each color component
        dstImageData(QuickVal + 2, y) = nColor
        dstImageData(QuickVal + 1, y) = nColor
        dstImageData(QuickVal, y) = nColor
        
    Next y
        If toPreview = False Then
            If (x And progBarCheck) = 0 Then SetProgBarVal x
        End If
    Next x
    
    'With our noise generation complete, point dstImageData() away from the DIB and deallocate it
    CopyMemory ByVal VarPtrArray(dstImageData), 0&, 4
    Erase dstImageData
    
    'Next, we need to soften the noise layer
    If Not toPreview Then Message "Softening film grain..."
    
    If gSoftness > 0 Then
    
        'If this is a preview, we need to adjust the softening radius to match the size of the preview box
        If toPreview Then
            If iWidth > iHeight Then
                gSoftness = (gSoftness / iWidth) * curLayerValues.Width
            Else
                gSoftness = (gSoftness / iHeight) * curLayerValues.Height
            End If
            If gSoftness = 0 Then gSoftness = 1
        End If
    
        gaussLayer.createFromExistingLayer workingLayer
    
        'Blur the noise texture as required by the user
        CreateGaussianBlurLayer gSoftness, noiseLayer, gaussLayer, toPreview, finalY * 2 + finalX * 2, finalX
        
    Else
        gaussLayer.createFromExistingLayer noiseLayer
    End If
    
    'Delete the original noise layer to conserve resources
    noiseLayer.eraseLayer
    Set noiseLayer = Nothing
        
    'We now have a softened noise layer.  Next, create three arrays - one pointing at the original image data, one pointing at
    ' the noise data, and one pointing at the destination data.
    prepImageData dstSA, toPreview, dstPic
    CopyMemory ByVal VarPtrArray(dstImageData()), VarPtr(dstSA), 4
    
    Dim srcImageData() As Byte
    Dim srcSA As SAFEARRAY2D
    prepSafeArray srcSA, srcLayer
    CopyMemory ByVal VarPtrArray(srcImageData()), VarPtr(srcSA), 4
        
    Dim GaussImageData() As Byte
    Dim gaussSA As SAFEARRAY2D
    prepSafeArray gaussSA, gaussLayer
    CopyMemory ByVal VarPtrArray(GaussImageData()), VarPtr(gaussSA), 4
        
    If Not toPreview Then Message "Applying film grain to image..."
    
    Dim r As Long, g As Long, b As Long
    
    'The final step of the smart blur function is to find edges, and replace them with the blurred data as necessary
    For x = initX To finalX
        QuickVal = x * qvDepth
    For y = initY To finalY
        
        'Retrieve the original image's pixels
        r = srcImageData(QuickVal + 2, y)
        g = srcImageData(QuickVal + 1, y)
        b = srcImageData(QuickVal, y)
                
        'Now, retrieve a noise pixel (we only need one, as each color component will be identical)
        nColor = GaussImageData(QuickVal, y) - 127
                
        'Add the noise to each color component
        r = r + nColor
        g = g + nColor
        b = b + nColor
        
        If r > 255 Then r = 255
        If r < 0 Then r = 0
        If g > 255 Then g = 255
        If g < 0 Then g = 0
        If b > 255 Then b = 255
        If b < 0 Then b = 0
        
        dstImageData(QuickVal + 2, y) = r
        dstImageData(QuickVal + 1, y) = g
        dstImageData(QuickVal, y) = b
        
    Next y
        If Not toPreview Then
            If (x And progBarCheck) = 0 Then SetProgBarVal finalX + x + finalY + finalY
        End If
    Next x
        
    'With our work complete, release all arrays
    CopyMemory ByVal VarPtrArray(GaussImageData), 0&, 4
    Erase GaussImageData
    
    gaussLayer.eraseLayer
    Set gaussLayer = Nothing
    
    CopyMemory ByVal VarPtrArray(srcImageData), 0&, 4
    Erase srcImageData
    
    srcLayer.eraseLayer
    Set srcLayer = Nothing
    
    CopyMemory ByVal VarPtrArray(dstImageData), 0&, 4
    Erase dstImageData
    
    'Pass control to finalizeImageData, which will handle the rest of the rendering
    finalizeImageData toPreview, dstPic
    
End Sub

Private Sub Form_Activate()
    
    'Note the current image's width and height, which will be needed to adjust the preview effect
    iWidth = pdImages(CurrentImage).Width
    iHeight = pdImages(CurrentImage).Height
    
    'Assign the system hand cursor to all relevant objects
    makeFormPretty Me
    
    'Render a preview
    updatePreview
    
End Sub

Private Sub Form_Unload(Cancel As Integer)
    ReleaseFormTheming Me
End Sub

'The next eight routines keep the value of the textbox and scroll bar in lock-step
Private Sub hsNoise_Change()
    copyToTextBoxI txtNoise, hsNoise.Value
    updatePreview
End Sub

Private Sub hsNoise_Scroll()
    copyToTextBoxI txtNoise, hsNoise.Value
    updatePreview
End Sub

Private Sub hsRadius_Change()
    copyToTextBoxI txtRadius, hsRadius.Value
    updatePreview
End Sub

Private Sub hsRadius_Scroll()
    copyToTextBoxI txtRadius, hsRadius.Value
    updatePreview
End Sub

Private Sub txtNoise_GotFocus()
    AutoSelectText txtNoise
End Sub

Private Sub txtNoise_KeyUp(KeyCode As Integer, Shift As Integer)
    textValidate txtNoise
    If EntryValid(txtNoise, hsNoise.Min, hsNoise.Max, False, False) Then hsNoise.Value = Val(txtNoise)
End Sub

Private Sub txtRadius_GotFocus()
    AutoSelectText txtRadius
End Sub

Private Sub txtRadius_KeyUp(KeyCode As Integer, Shift As Integer)
    textValidate txtRadius
    If EntryValid(txtRadius, hsRadius.Min, hsRadius.Max, False, False) Then hsRadius.Value = Val(txtRadius)
End Sub

Private Sub updatePreview()
    AddFilmGrain hsNoise.Value, hsRadius.Value, True, fxPreview
End Sub
