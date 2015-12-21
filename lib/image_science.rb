#!/usr/local/bin/ruby -w

require 'rubygems'
require 'inline'

##
# Provides a clean and simple API to generate thumbnails using
# FreeImage as the underlying mechanism.
#
# For more information or if you have build issues with FreeImage, see
# http://seattlerb.rubyforge.org/ImageScience.html

class ImageScience
  VERSION = '1.2.6'

  ##
  # The top-level image loader opens +path+ and then yields the image.
  #
  # :singleton-method: with_image

  ##
  # The top-level image loader, opens an image from the string +data+
  # and then yields the image.
  #
  # :singleton-method: with_image_from_memory

  ##
  # Crops an image to +left+, +top+, +right+, and +bottom+ and then
  # yields the new image.
  #
  # :method: with_crop

  ##
  # Returns the width of the image, in pixels.
  #
  # :method: width

  ##
  # Returns the height of the image, in pixels.
  #
  # :method: height

  ##
  # Saves the image out to +path+. Changing the file extension will
  # convert the file type to the appropriate format.
  #
  # :method: save

  ##
  # Resizes the image to +width+ and +height+ using a cubic-bspline
  # filter and yields the new image.
  #
  # :method: resize
  
  ##
  # Creates a proportional thumbnail of the image scaled so its longest
  # edge is resized to +size+ and yields the new image.

  def thumbnail(size, greyscale = false) # :yields: image
    w, h = size[0], size[1]

    self.resize(w.to_i, h.to_i, greyscale) do |image|
      yield image
    end
  end

  ##
  # Creates a square thumbnail of the image cropping the longest edge
  # to match the shortest edge, resizes to +size+, and yields the new
  # image.

  def cropped_thumbnail(size, greyscale = false) # :yields: image
    w, h = width, height
    l, t, r, b, half = 0, 0, w, h, (w - h).abs / 2

    l, r = half, half + h if w > h
    t, b = half, half + w if h > w

    with_crop(l, t, r, b) do |img|
      img.thumbnail(size, greyscale) do |thumb|
        yield thumb
      end
    end
  end

  inline do |builder|
    %w[/opt/local /usr/local ./.heroku/vendor].each do |dir|
      if File.directory? "#{dir}/include" then
        builder.add_compile_flags "-I#{dir}/include"
        builder.add_link_flags "-L#{dir}/lib"
      end
    end

    builder.add_link_flags "-lfreeimage"
    unless RUBY_PLATFORM =~ /mswin/
      builder.add_link_flags "-lfreeimage"
      # TODO: detect PPC
      builder.add_link_flags "-lstdc++" # only needed on PPC for some reason
    else
      builder.add_link_flags "freeimage.lib"
    end
    builder.include '"FreeImage.h"'

    builder.prefix <<-"END"
      #define GET_BITMAP(name) Data_Get_Struct(self, FIBITMAP, (name)); if (!(name)) rb_raise(rb_eTypeError, "Bitmap has already been freed");
      static ID err_key; /* used as thread-local key */
      static void raise_deferred(void);
    END

    builder.prefix <<-"END"
      VALUE unload(VALUE self) {
        FIBITMAP *bitmap;
        GET_BITMAP(bitmap);

        FreeImage_Unload(bitmap);
        DATA_PTR(self) = NULL;
        raise_deferred(); /* raise just in case */
        return Qnil;
      }
    END

    builder.prefix <<-"END"
      static VALUE raise_or_yield(VALUE obj) {
        /*
         * check for FreeImage routines which may warn or error out,
         * do not run user code if there are warnings/errors here:
         */
        raise_deferred();

        return rb_yield(obj);
      }

      VALUE wrap_and_yield(FIBITMAP *image, VALUE self, FREE_IMAGE_FORMAT fif) {
        unsigned int self_is_class = rb_type(self) == T_CLASS;
        VALUE klass = self_is_class ? self         : CLASS_OF(self);
        VALUE type  = self_is_class ? INT2FIX(fif) : rb_iv_get(self, "@file_type");
        VALUE obj = Data_Wrap_Struct(klass, NULL, NULL, image);
        rb_iv_set(obj, "@file_type", type);
        return rb_ensure(raise_or_yield, obj, unload, obj);
      }
    END

    builder.prefix <<-"END"
      void copy_icc_profile(VALUE self, FIBITMAP *from, FIBITMAP *to) {
        FREE_IMAGE_FORMAT fif = FIX2INT(rb_iv_get(self, "@file_type"));
        if (fif != FIF_PNG && FreeImage_FIFSupportsICCProfiles(fif)) {
          FIICCPROFILE *profile = FreeImage_GetICCProfile(from);
          if (profile && profile->data) {
            FreeImage_CreateICCProfile(to, profile->data, profile->size);
          }
        }
      }
    END

    # we defer raising the error until it we find a safe point to do so
    # We cannot use rb_ensure in these cases because FreeImage may internally
    # make allocations via which our code will never see.
    builder.prefix <<-"END"
      void FreeImageErrorHandler(FREE_IMAGE_FORMAT fif, const char *message) {
        VALUE err = rb_sprintf(
                 "FreeImage exception for type %s: %s",
                  (fif == FIF_UNKNOWN) ? "???" : FreeImage_GetFormatFromFIF(fif),
                  message);
        rb_thread_local_aset(rb_thread_current(), err_key, err);
      }
    END

    # do not call this until necessary variables are wrapped up for GC
    # otherwise there will be leaks
    builder.prefix <<-"END"
      static void raise_deferred(void) {
        VALUE err = rb_thread_local_aref(rb_thread_current(), err_key);
        if (!NIL_P(err)) {
          rb_thread_local_aset(rb_thread_current(), err_key, Qnil);
          rb_raise(rb_eRuntimeError, "%s", StringValueCStr(err));
        }
      }
    END

    builder.prefix <<-"END"
      FIBITMAP* ReOrient(FIBITMAP *bitmap) {
        FITAG *tagValue = NULL;
        FIBITMAP *oldBitmap = bitmap;
        FreeImage_GetMetadata(FIMD_EXIF_MAIN, bitmap, "Orientation", &tagValue);
        switch (tagValue == NULL ? 0 : *((short *) FreeImage_GetTagValue(tagValue))) {
          case 6:
            bitmap = FreeImage_RotateClassic(bitmap, 270);
            break;
          case 3:
            bitmap = FreeImage_RotateClassic(bitmap, 180);
            break;
          case 8:
            bitmap = FreeImage_RotateClassic(bitmap, 90);
            break;
          default:
            bitmap = FreeImage_Clone(bitmap);
            break;
        }
        FreeImage_Unload(oldBitmap);
        return bitmap;
      }
    END

    builder.add_to_init "FreeImage_SetOutputMessage(FreeImageErrorHandler);"
    builder.add_to_init 'err_key = rb_intern("__FREE_IMAGE_ERROR");'

    builder.c_singleton <<-"END"
      VALUE with_image(char * input) {
        FREE_IMAGE_FORMAT fif = FIF_UNKNOWN;
        int flags;

        fif = FreeImage_GetFileType(input, 0);
        if (fif == FIF_UNKNOWN) fif = FreeImage_GetFIFFromFilename(input);
        if ((fif != FIF_UNKNOWN) && FreeImage_FIFSupportsReading(fif)) {
          FIBITMAP *bitmap;
          VALUE result = Qnil;
          flags = fif == FIF_JPEG ? JPEG_ACCURATE : 0;
          if ((bitmap = FreeImage_Load(fif, input, flags))) {
            bitmap = ReOrient(bitmap);
            result = wrap_and_yield(bitmap, self, fif);
          }
          raise_deferred();
          return result;
        }
        rb_raise(rb_eTypeError, "Unknown file format");
        return Qnil;
      }
    END

    builder.c_singleton <<-"END"
      VALUE with_image_from_memory(VALUE image_data) {
        FREE_IMAGE_FORMAT fif = FIF_UNKNOWN;
        BYTE *image_data_ptr;
        DWORD image_data_length;
        FIMEMORY *stream;
        FIBITMAP *bitmap = NULL;
        VALUE result = Qnil;
        int flags;

        Check_Type(image_data, T_STRING);
        image_data_ptr    = (BYTE*)RSTRING_PTR(image_data);
        image_data_length = (DWORD)RSTRING_LEN(image_data);
        stream = FreeImage_OpenMemory(image_data_ptr, image_data_length);

        if (NULL == stream) {
          rb_raise(rb_eTypeError, "Unable to open image_data");
        }

        fif = FreeImage_GetFileTypeFromMemory(stream, 0);
        if ((fif == FIF_UNKNOWN) || !FreeImage_FIFSupportsReading(fif)) {
          rb_raise(rb_eTypeError, "Unknown file format");
        }

        flags = fif == FIF_JPEG ? JPEG_ACCURATE : 0;
        bitmap = FreeImage_LoadFromMemory(fif, stream, flags);
        FreeImage_CloseMemory(stream);
        if (bitmap) {
          bitmap = ReOrient(bitmap);
          result = wrap_and_yield(bitmap, self, fif);
        }
        raise_deferred();
        return result;
      }
    END

    builder.c <<-"END"
      VALUE with_crop(int l, int t, int r, int b) {
        FIBITMAP *copy, *bitmap;
        VALUE result = Qnil;
        GET_BITMAP(bitmap);

        if ((copy = FreeImage_Copy(bitmap, l, t, r, b))) {
          copy_icc_profile(self, bitmap, copy);
          result = wrap_and_yield(copy, self, 0);
        }
        raise_deferred();
        return result;
      }
    END

    builder.c <<-"END"
      int height() {
        FIBITMAP *bitmap;
        GET_BITMAP(bitmap);

        return FreeImage_GetHeight(bitmap);
      }
    END

    builder.c <<-"END"
      int width() {
        FIBITMAP *bitmap;
        GET_BITMAP(bitmap);

        return FreeImage_GetWidth(bitmap);
      }
    END

    builder.c <<-"END"
      VALUE resize(int w, int h, int greyscale) {
        FIBITMAP *bitmap, *image;
        if (w <= 0) rb_raise(rb_eArgError, "Width <= 0");
        if (h <= 0) rb_raise(rb_eArgError, "Height <= 0");
        GET_BITMAP(bitmap);
        image = FreeImage_Rescale(bitmap, w, h, FILTER_CATMULLROM);
        if (image) {
          if (greyscale > 0) {
            RGBQUAD a_colors[64];
            RGBQUAD b_colors[64];
        
            int grey_point = 192;
        
            for (int i=grey_point;i<256;i++)
            {
               a_colors[i - grey_point].rgbRed = i;
               a_colors[i - grey_point].rgbGreen = i;
               a_colors[i - grey_point].rgbBlue = i;

               b_colors[i - grey_point].rgbRed = grey_point;
               b_colors[i - grey_point].rgbGreen = grey_point;
               b_colors[i - grey_point].rgbBlue = grey_point;
            }
        
            FIBITMAP *grey = FreeImage_ConvertToGreyscale(image);
            FreeImage_Unload(image);
        
            if (grey) {
              int result = FreeImage_ApplyColorMapping(grey, a_colors, b_colors, 64, TRUE, FALSE);
              image = grey;
            }
          }
          copy_icc_profile(self, bitmap, image);
          return wrap_and_yield(image, self, 0);
        }
        raise_deferred();
        return Qnil;
      }
    END

    builder.c <<-"END"
      VALUE save(char * output) {
        int flags;
        FIBITMAP *bitmap;
        FREE_IMAGE_FORMAT fif = FreeImage_GetFIFFromFilename(output);
        if (fif == FIF_UNKNOWN) fif = FIX2INT(rb_iv_get(self, "@file_type"));
        if ((fif != FIF_UNKNOWN) && FreeImage_FIFSupportsWriting(fif)) {
          BOOL result = 0, unload = 0;
          GET_BITMAP(bitmap);
          flags = fif == FIF_JPEG ? JPEG_QUALITYSUPERB : 0;

          if (fif == FIF_PNG) FreeImage_DestroyICCProfile(bitmap);
          if (fif == FIF_JPEG && FreeImage_GetBPP(bitmap) != 24)
            bitmap = FreeImage_ConvertTo24Bits(bitmap), unload = 1; // sue me

          result = FreeImage_Save(fif, bitmap, output, flags);

          if (unload) FreeImage_Unload(bitmap);

          raise_deferred();
          return result ? Qtrue : Qfalse;
        }
        rb_raise(rb_eTypeError, "Unknown file format");
        return Qnil;
      }
    END
  end
end
