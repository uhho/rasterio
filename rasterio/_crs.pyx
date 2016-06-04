"""Coordinate reference systems, class and functions.
"""

import json
import logging

from rasterio cimport _gdal, _base
from rasterio.compat import UserDict
from rasterio.errors import CRSError
from rasterio.compat import string_types

log = logging.getLogger(__name__)

class CRS(UserDict):
    """A container class for coordinate reference system info

    PROJ.4 is the law of this land: http://proj.osgeo.org/. But whereas PROJ.4
    coordinate reference systems are described by strings of parameters such as

        +proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs

    here we use mappings:

        {'proj': 'longlat', 'ellps': 'WGS84', 'datum': 'WGS84', 'no_defs': True}

    One can set/get any PROJ.4 parameter using a dict-like key/value pair on the
    object. You can instantiate the object by simply passing a dict to the
    constructor. E.g.

        crs = CRS({'init': 'epsg:3005'})

    """
    def is_valid(self):
        """Check if valid geographic or projected coordinate reference system."""
        return self.is_geographic() or self.is_projected()

    def is_geographic(self):
        cdef void *osr_crs = _base._osr_from_crs(self)
        cdef int retval = _gdal.OSRIsGeographic(osr_crs)
        _gdal.OSRDestroySpatialReference(osr_crs)
        return retval == 1

    def is_projected(self):
        cdef void *osr_crs = _base._osr_from_crs(self)
        cdef int retval = _gdal.OSRIsProjected(osr_crs)
        _gdal.OSRDestroySpatialReference(osr_crs)
        return retval == 1

    def is_epsg_code(self):
        for val in self.values():
            if isinstance(val, string_types) and val.lower().startswith('epsg'):
                return True
        return False

    def __eq__(self, other):
        cdef void *osr_crs1 = _base._osr_from_crs(self)
        cdef void *osr_crs2 = _base._osr_from_crs(other)
        cdef int retval = _gdal.OSRIsSame(osr_crs1, osr_crs2)
        _gdal.OSRDestroySpatialReference(osr_crs1)
        _gdal.OSRDestroySpatialReference(osr_crs2)
        return retval == 1

    def to_string(self):
        """Turn a parameter mapping into a more conventional PROJ.4 string.

        Mapping keys are tested against the ``all_proj_keys`` list. Values of
        ``True`` are omitted, leaving the key bare: {'no_defs': True} -> "+no_defs"
        and items where the value is otherwise not a str, int, or float are
        omitted.
        """
        items = []
        for k, v in sorted(filter(
                lambda x: x[0] in all_proj_keys and x[1] is not False and (
                    isinstance(x[1], (bool, int, float)) or
                    isinstance(x[1], string_types)),
                self.items())):
            items.append(
                "+" + "=".join(
                    map(str, filter(
                        lambda y: (y or y == 0) and y is not True, (k, v)))))
        return " ".join(items)

    @staticmethod
    def from_string(prjs):
        """Turn a PROJ.4 string into a mapping of parameters.

        Bare parameters like "+no_defs" are given a value of ``True``. All keys
        are checked against the ``all_proj_keys`` list.

        EPSG:nnnn is allowed.

        JSON text-encoded strings are allowed.
        """
        if '{' in prjs:
            # may be json, try to decode it
            try:
                val = json.loads(prjs, strict=False)
            except ValueError:
                raise CRSError('crs appears to be JSON but is not valid')

            if not val:
                raise CRSError("crs is empty JSON")
            else:
                return val

        if prjs.strip().upper().startswith('EPSG:'):
            return CRS.from_epsg(prjs.split(':')[1])

        parts = [o.lstrip('+') for o in prjs.strip().split()]

        def parse(v):
            if v in ('True', 'true'):
                return True
            elif v in ('False', 'false'):
                return False
            else:
                try:
                    return int(v)
                except ValueError:
                    pass
                try:
                    return float(v)
                except ValueError:
                    return v

        items = map(
            lambda kv: len(kv) == 2 and (kv[0], parse(kv[1])) or (kv[0], True),
            (p.split('=') for p in parts))

        out = CRS((k, v) for k, v in items if k in all_proj_keys)

        if not out:
            raise CRSError("crs is empty or invalid: {}".format(prjs))

        return out

    @staticmethod
    def from_epsg(code):
        """Given an integer code, returns an EPSG-like mapping.

        Note: the input code is not validated against an EPSG database.
        """
        if int(code) <= 0:
            raise ValueError("EPSG codes are positive integers")
        return CRS(init="epsg:%s" % code, no_defs=True)

    @property
    def wkt(self):
        cdef char *srcwkt = NULL
        cdef void *osr = _base._osr_from_crs(self)
        try:
            _gdal.OSRExportToWkt(osr, &srcwkt)
            wkt = srcwkt.decode('utf-8')
        finally:
            _gdal.CPLFree(srcwkt)
            _gdal.OSRDestroySpatialReference(osr)
        return wkt

# Below is the big list of PROJ4 parameters from
# http://trac.osgeo.org/proj/wiki/GenParms.
# It is parsed into a list of parameter keys ``all_proj_keys``.

_param_data = """
+a         Semimajor radius of the ellipsoid axis
+alpha     ? Used with Oblique Mercator and possibly a few others
+axis      Axis orientation (new in 4.8.0)
+b         Semiminor radius of the ellipsoid axis
+datum     Datum name (see `proj -ld`)
+ellps     Ellipsoid name (see `proj -le`)
+init      Initialize from a named CRS
+k         Scaling factor (old name)
+k_0       Scaling factor (new name)
+lat_0     Latitude of origin
+lat_1     Latitude of first standard parallel
+lat_2     Latitude of second standard parallel
+lat_ts    Latitude of true scale
+lon_0     Central meridian
+lonc      ? Longitude used with Oblique Mercator and possibly a few others
+lon_wrap  Center longitude to use for wrapping (see below)
+nadgrids  Filename of NTv2 grid file to use for datum transforms (see below)
+no_defs   Don't use the /usr/share/proj/proj_def.dat defaults file
+over      Allow longitude output outside -180 to 180 range, disables wrapping (see below)
+pm        Alternate prime meridian (typically a city name, see below)
+proj      Projection name (see `proj -l`)
+south     Denotes southern hemisphere UTM zone
+to_meter  Multiplier to convert map units to 1.0m
+towgs84   3 or 7 term datum transform parameters (see below)
+units     meters, US survey feet, etc.
+vto_meter vertical conversion to meters.
+vunits    vertical units.
+x_0       False easting
+y_0       False northing
+zone      UTM zone
+a         Semimajor radius of the ellipsoid axis
+alpha     ? Used with Oblique Mercator and possibly a few others
+azi
+b         Semiminor radius of the ellipsoid axis
+belgium
+beta
+czech
+e         Eccentricity of the ellipsoid = sqrt(1 - b^2/a^2) = sqrt( f*(2-f) )
+ellps     Ellipsoid name (see `proj -le`)
+es        Eccentricity of the ellipsoid squared
+f         Flattening of the ellipsoid (often presented as an inverse, e.g. 1/298)
+gamma
+geoc
+guam
+h
+k         Scaling factor (old name)
+K
+k_0       Scaling factor (new name)
+lat_0     Latitude of origin
+lat_1     Latitude of first standard parallel
+lat_2     Latitude of second standard parallel
+lat_b
+lat_t
+lat_ts    Latitude of true scale
+lon_0     Central meridian
+lon_1
+lon_2
+lonc      ? Longitude used with Oblique Mercator and possibly a few others
+lsat
+m
+M
+n
+no_cut
+no_off
+no_rot
+ns
+o_alpha
+o_lat_1
+o_lat_2
+o_lat_c
+o_lat_p
+o_lon_1
+o_lon_2
+o_lon_c
+o_lon_p
+o_proj
+over
+p
+path
+proj      Projection name (see `proj -l`)
+q
+R
+R_a
+R_A       Compute radius such that the area of the sphere is the same as the area of the ellipsoid
+rf        Reciprocal of the ellipsoid flattening term (e.g. 298)
+R_g
+R_h
+R_lat_a
+R_lat_g
+rot
+R_V
+s
+south     Denotes southern hemisphere UTM zone
+sym
+t
+theta
+tilt
+to_meter  Multiplier to convert map units to 1.0m
+units     meters, US survey feet, etc.
+vopt
+W
+westo
+x_0       False easting
+y_0       False northing
+zone      UTM zone
"""

_lines = filter(lambda x: len(x) > 1, _param_data.split("\n"))
all_proj_keys = list(
    set(line.split()[0].lstrip("+").strip() for line in _lines)
    ) + ['no_mayo']
