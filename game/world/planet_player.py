"""Planet surface explorer movement."""
import math

MAX_MODIFIER_KEYS = 3
MIN_COS_LATITUDE = 1e-6
SPEED_BASE_MULTIPLIER = 4


class PlanetPlayer:
    """Player that moves along a planet surface."""

    def __init__(self, latitude=0.0, longitude=0.0, heading=0.0):
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading

    def adjust_heading(self, delta):
        """Adjust heading by delta radians."""
        self.heading = (self.heading + delta) % (2 * math.pi)

    def speed_multiplier(self, modifier_key_count):
        """Return speed multiplier based on modifier key count."""
        count = max(0, min(MAX_MODIFIER_KEYS, int(modifier_key_count)))
        return SPEED_BASE_MULTIPLIER ** count

    def move(self, forward, strafe, base_speed, modifier_key_count, planet_radius):
        """Move along surface using radian lat/lon and distance units."""
        if planet_radius <= 0:
            return self.latitude, self.longitude
        if forward == 0 and strafe == 0:
            return self.latitude, self.longitude
        multiplier = self.speed_multiplier(modifier_key_count)
        distance = base_speed * multiplier
        direction = math.atan2(strafe, forward)
        travel_heading = self.heading + direction
        delta_lat = math.cos(travel_heading) * distance / planet_radius
        delta_lon = math.sin(travel_heading) * distance / (
            planet_radius * max(MIN_COS_LATITUDE, math.cos(self.latitude))
        )
        self.latitude = max(-math.pi / 2, min(math.pi / 2, self.latitude + delta_lat))
        self.longitude = (self.longitude + delta_lon + math.pi) % (2 * math.pi) - math.pi
        return self.latitude, self.longitude
