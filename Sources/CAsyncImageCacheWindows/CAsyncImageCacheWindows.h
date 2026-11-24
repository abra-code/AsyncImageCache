#ifndef ASYNCIMAGECACHE_CWINDOWS_H
#define ASYNCIMAGECACHE_CWINDOWS_H

// WinHTTP, for loading http and https URLs on Windows, and BCrypt, for the SHA-256 that names the disk cache's
// files. Swift's WinSDK module has neither; windows.h comes from it.
#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>
// WinRT's activation and strings (RoActivateInstance, RoGetActivationFactory, WindowsCreateString), for the image a
// WinUI program shows.
#include <inspectable.h>
#include <roapi.h>
#include <winstring.h>

// The few WinRT interfaces the store uses to hand a WinUI program a ready image, declared here as their C ABI:
// Swift's WinSDK module has no WinRT types, and WinUI 3 ships no C headers. The IIDs, the method order (the vtable
// after IInspectable's six methods, or IUnknown's three) and the enum values are read from the metadata
// (Windows.Foundation.UniversalApiContract.winmd and Windows.Foundation.FoundationContract.winmd of the Windows SDK,
// Microsoft.UI.Xaml.winmd of the Windows App SDK 2.7). A method the store never calls is a placeholder slot.
// Enum arguments are 32-bit integers in the ABI.

// Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, BitmapBufferAccessMode.Write
// and .Read.
#define AIC_BITMAP_PIXEL_FORMAT_BGRA8 87
#define AIC_BITMAP_ALPHA_MODE_PREMULTIPLIED 0
#define AIC_BITMAP_BUFFER_ACCESS_READ 0
#define AIC_BITMAP_BUFFER_ACCESS_WRITE 2

// IInspectable's methods, first in every WinRT interface.
#define AIC_INSPECTABLE_SLOTS(Interface) \
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(Interface *This, REFIID riid, void **object); \
    ULONG (STDMETHODCALLTYPE *AddRef)(Interface *This); \
    ULONG (STDMETHODCALLTYPE *Release)(Interface *This); \
    void *GetIids; \
    void *GetRuntimeClassName; \
    void *GetTrustLevel;

// Windows.Graphics.Imaging.BitmapPlaneDescription.
typedef struct AICBitmapPlaneDescription {
    INT32 StartIndex;
    INT32 Width;
    INT32 Height;
    INT32 Stride;
} AICBitmapPlaneDescription;

// Windows.Foundation.IClosable, 30D5A829-7FA4-4026-83BB-D75BAE4EA99E.
typedef struct AICClosable AICClosable;
typedef struct AICClosableVtbl {
    AIC_INSPECTABLE_SLOTS(AICClosable)
    HRESULT (STDMETHODCALLTYPE *Close)(AICClosable *This);
} AICClosableVtbl;
struct AICClosable { const AICClosableVtbl *lpVtbl; };

// Windows.Foundation.IMemoryBufferReference, FBC4DD29-245B-11E4-AF98-689423260CF8.
typedef struct AICMemoryBufferReference AICMemoryBufferReference;
typedef struct AICMemoryBufferReferenceVtbl {
    AIC_INSPECTABLE_SLOTS(AICMemoryBufferReference)
    HRESULT (STDMETHODCALLTYPE *get_Capacity)(AICMemoryBufferReference *This, UINT32 *value);
} AICMemoryBufferReferenceVtbl;
struct AICMemoryBufferReference { const AICMemoryBufferReferenceVtbl *lpVtbl; };

// IMemoryBufferByteAccess (MemoryBuffer.h, a COM interface on IUnknown), 5B0D3235-4DBA-4D44-865E-8F1D0E4FD04D.
typedef struct AICMemoryBufferByteAccess AICMemoryBufferByteAccess;
typedef struct AICMemoryBufferByteAccessVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(AICMemoryBufferByteAccess *This, REFIID riid, void **object);
    ULONG (STDMETHODCALLTYPE *AddRef)(AICMemoryBufferByteAccess *This);
    ULONG (STDMETHODCALLTYPE *Release)(AICMemoryBufferByteAccess *This);
    HRESULT (STDMETHODCALLTYPE *GetBuffer)(AICMemoryBufferByteAccess *This, BYTE **value, UINT32 *capacity);
} AICMemoryBufferByteAccessVtbl;
struct AICMemoryBufferByteAccess { const AICMemoryBufferByteAccessVtbl *lpVtbl; };

// Windows.Foundation.IMemoryBuffer, FBC4DD2A-245B-11E4-AF98-689423260CF8.
typedef struct AICMemoryBuffer AICMemoryBuffer;
typedef struct AICMemoryBufferVtbl {
    AIC_INSPECTABLE_SLOTS(AICMemoryBuffer)
    HRESULT (STDMETHODCALLTYPE *CreateReference)(AICMemoryBuffer *This, AICMemoryBufferReference **reference);
} AICMemoryBufferVtbl;
struct AICMemoryBuffer { const AICMemoryBufferVtbl *lpVtbl; };

// Windows.Graphics.Imaging.IBitmapBuffer, A53E04C4-399C-438C-B28F-A63A6B83D1A1.
typedef struct AICBitmapBuffer AICBitmapBuffer;
typedef struct AICBitmapBufferVtbl {
    AIC_INSPECTABLE_SLOTS(AICBitmapBuffer)
    HRESULT (STDMETHODCALLTYPE *GetPlaneCount)(AICBitmapBuffer *This, INT32 *value);
    HRESULT (STDMETHODCALLTYPE *GetPlaneDescription)(AICBitmapBuffer *This, INT32 index, AICBitmapPlaneDescription *value);
} AICBitmapBufferVtbl;
struct AICBitmapBuffer { const AICBitmapBufferVtbl *lpVtbl; };

// Windows.Graphics.Imaging.ISoftwareBitmap, 689E0708-7EEF-483F-963F-DA938818E073.
typedef struct AICSoftwareBitmap AICSoftwareBitmap;
typedef struct AICSoftwareBitmapVtbl {
    AIC_INSPECTABLE_SLOTS(AICSoftwareBitmap)
    void *get_BitmapPixelFormat;
    void *get_BitmapAlphaMode;
    HRESULT (STDMETHODCALLTYPE *get_PixelWidth)(AICSoftwareBitmap *This, INT32 *value);
    HRESULT (STDMETHODCALLTYPE *get_PixelHeight)(AICSoftwareBitmap *This, INT32 *value);
    void *get_IsReadOnly;
    void *put_DpiX;
    void *get_DpiX;
    void *put_DpiY;
    void *get_DpiY;
    HRESULT (STDMETHODCALLTYPE *LockBuffer)(AICSoftwareBitmap *This, INT32 mode, AICBitmapBuffer **value);
} AICSoftwareBitmapVtbl;
struct AICSoftwareBitmap { const AICSoftwareBitmapVtbl *lpVtbl; };

// Windows.Graphics.Imaging.ISoftwareBitmapFactory, C99FEB69-2D62-4D47-A6B3-4FDB6A07FDF8.
typedef struct AICSoftwareBitmapFactory AICSoftwareBitmapFactory;
typedef struct AICSoftwareBitmapFactoryVtbl {
    AIC_INSPECTABLE_SLOTS(AICSoftwareBitmapFactory)
    void *Create;
    HRESULT (STDMETHODCALLTYPE *CreateWithAlpha)(AICSoftwareBitmapFactory *This, INT32 format, INT32 width, INT32 height,
                                                 INT32 alpha, AICSoftwareBitmap **value);
} AICSoftwareBitmapFactoryVtbl;
struct AICSoftwareBitmapFactory { const AICSoftwareBitmapFactoryVtbl *lpVtbl; };

// Microsoft.UI.Xaml.Media.Imaging.ISoftwareBitmapSource (WinUI 3), A6ACA802-1F24-5A1E-BF08-781A85ED5511.
// SetBitmapAsync's result is a Windows.Foundation.IAsyncAction, which the store only releases.
typedef struct AICSoftwareBitmapSource AICSoftwareBitmapSource;
typedef struct AICSoftwareBitmapSourceVtbl {
    AIC_INSPECTABLE_SLOTS(AICSoftwareBitmapSource)
    HRESULT (STDMETHODCALLTYPE *SetBitmapAsync)(AICSoftwareBitmapSource *This, AICSoftwareBitmap *softwareBitmap,
                                                IInspectable **operation);
} AICSoftwareBitmapSourceVtbl;
struct AICSoftwareBitmapSource { const AICSoftwareBitmapSourceVtbl *lpVtbl; };

#undef AIC_INSPECTABLE_SLOTS

#endif
