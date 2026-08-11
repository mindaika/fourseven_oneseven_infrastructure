"""Generate ha_metrics.toml from the reviewed allowlist.

The ID lists below ARE the review — they were checked by hand against the
device registry. Unit metadata is pulled from HA so it is accurate rather
than retyped, but membership is never inferred from units.
"""
import sqlite3, sys

# --- reviewed allowlist -------------------------------------------------
ENV_TEMP = [
    "sensor.my_ecobee_current_temperature",
    "sensor.lil_bee_temperature",
]
# Real historical data, feed died 2026-02-17. Archived, not charted.
ENV_TEMP_DEAD = [
    "sensor.acurite1_temperature",
    "sensor.acurite2_temperature",
    "sensor.tp357s_3d05_temperature",
]
MACHINE_TEMP = [
    "sensor.hermano_temperature",
    "sensor.hermano_drive_1_temperature",
    "sensor.hermano_drive_2_temperature",
    "sensor.pi5_composite_temperature",
    "sensor.piberry4lite_cpu_thermal_0_temperature",
    "sensor.192_168_1_96_cpu_thermal_0_temperature",
    "sensor.inovelli_vzm31_sn_internal_temperature",
]
HOME_ENERGY = ["opower:pgn_elec_6537807941_energy_consumption"]

ENERGY_LIFETIME = [
    "sensor.p1_total_consumption", "sensor.p2_total_consumption",
    "sensor.p3_total_consumption", "sensor.g1_total_consumption",
    "sensor.schoolhouse_total_consumption",
    "sensor.schoolhouse_blue_total_consumption",
    "sensor.aqara_g1_summation_delivered",
    "sensor.aqara_lumi_light_agl001_summation_delivered",
    "sensor.inovelli_vzm31_sn_summation_delivered",
    "sensor.r1_summation_delivered", "sensor.r2_summation_delivered",
    "sensor.r3_summation_delivered",
    # Dead 2026-06-05 but holds 151 kWh of real history worth archiving.
    "sensor.eve_energy_energy_top",
]
# No lifetime meter exists for these devices; daily-cycle sensor is the
# only source. HA's reset-aware `sum` makes it valid (verified).
ENERGY_CYCLE = [f"sensor.{d}_today_s_consumption" for d in (
    "headphones", "plant_light", "computer", "laptop", "record_player",
    "rembrandt", "humidifier", "mid_fan", "alarm_clock",
    "bedroom_tapo_1_top", "bedroom_tapo_1_bottom",
    "tall_bookshelf_right_top", "tall_bookshelf_right_bottom",
    "yr_west_1_bottom")]

DEVICE_POWER = [
    "sensor.alarm_clock_current_consumption", "sensor.aqara_g1_power",
    "sensor.aqara_lumi_light_agl001_power",
    "sensor.bedroom_tapo_1_bottom_current_consumption",
    "sensor.bedroom_tapo_1_top_current_consumption",
    "sensor.computer_current_consumption", "sensor.eve_energy_power_top",
    "sensor.g1_current_consumption", "sensor.headphones_current_consumption",
    "sensor.humidifier_current_consumption", "sensor.inovelli_vzm31_sn_power",
    "sensor.laptop_current_consumption", "sensor.mid_fan_current_consumption",
    "sensor.p1_current_consumption", "sensor.p2_current_consumption",
    "sensor.p3_current_consumption", "sensor.plant_light_current_consumption",
    "sensor.r1_instantaneous_demand", "sensor.r2_instantaneous_demand",
    "sensor.r3_instantaneous_demand", "sensor.record_player_current_consumption",
    "sensor.rembrandt_current_consumption",
    "sensor.schoolhouse_blue_current_consumption",
    "sensor.schoolhouse_current_consumption",
    "sensor.tall_bookshelf_right_bottom_current_consumption",
    "sensor.tall_bookshelf_right_top_current_consumption",
    "sensor.yr_west_1_bottom_current_consumption",
]

INACTIVE = ({"sensor.eve_energy_power_top", "sensor.eve_energy_energy_top"}
            | set(ENV_TEMP_DEAD))

# Reviewed exclusions. Recording WHY lets the discovery audit alarm only on
# genuinely new metrics instead of re-reporting settled decisions forever.
LIFETIME_DEVICES = ("g1", "p1", "p2", "p3", "schoolhouse", "schoolhouse_blue")


def exclusion_reason(sid, unit_class):
    if sid.endswith("_this_month_s_consumption"):
        return "monthly cycle duplicate; daily cycle is the finer-grained source"
    if sid.endswith("_today_s_consumption"):
        dev = sid[len("sensor."):-len("_today_s_consumption")]
        if dev in LIFETIME_DEVICES:
            return f"superseded by sensor.{dev}_total_consumption (lifetime meter)"
        return "unreviewed daily cycle sensor"
    if sid.startswith("sensor.elec_account_"):
        return ("opower-derived billing sensor; canonical series is "
                "opower:*_energy_consumption")
    if sid.endswith("_energy_return"):
        return ("all-zero across 5020 rows (max_sum=0.0); no solar export "
                "on this account")
    if sid in ("sensor.computer_energy_this_month_wh", "sensor.eve_monthly_cycle"):
        return ("monthly cycle over the same source as "
                "sensor.computer_today_s_consumption")
    if sid.startswith("sensor.pi5_") and unit_class == "temperature":
        return "1-row artifact of a renamed integration; no usable history"
    if sid.endswith(("_energy_cost", "_energy_compensation")):
        # 5020 rows each, same grain ranges as consumption. Cheap to add
        # later behind a 'home_cost' category; out of scope for now.
        return "USD cost/compensation, not energy; out of scope for this phase"
    return None

# Plausibility ceiling as sustained average POWER (kW), not kWh: grain-agnostic,
# so one value works for hourly, daily and billing-period buckets.
#   ceiling_kwh = max_plausible_kw * bucket_hours
KW_BULB, KW_OUTLET, KW_HOME = 0.05, 2.0, 25.0
BULBS = ("r1_", "r2_", "r3_", "aqara_lumi_light")


def ceiling(sid):
    if sid.startswith("opower:"):
        return KW_HOME
    return KW_BULB if any(b in sid for b in BULBS) else KW_OUTLET


def tomlstr(v):
    """TOML string, or `false` as the explicit absent marker (TOML has no null)."""
    return f'"{v}"' if v else "false"


def label(sid, ha_name):
    if ha_name:
        return ha_name
    base = sid.split(".", 1)[1] if "." in sid else sid
    for suf in ("_today_s_consumption", "_total_consumption",
                "_summation_delivered", "_current_consumption",
                "_instantaneous_demand", "_temperature", "_power"):
        base = base.removesuffix(suf)
    return base.replace("_", " ").title()


con = sqlite3.connect("file:/config/home-assistant_v2.db?mode=ro", uri=True)
meta = {r[0]: r[1:] for r in con.execute(
    "SELECT statistic_id, unit_of_measurement, unit_class, mean_type, has_sum, source, name "
    "FROM statistics_meta")}

groups = [
    ("environmental_temperature", ENV_TEMP + ENV_TEMP_DEAD, None),
    ("machine_temperature",       MACHINE_TEMP,              None),
    ("home_energy",               HOME_ENERGY,               "lifetime"),
    ("device_energy",             ENERGY_LIFETIME,           "lifetime"),
    ("device_energy",             ENERGY_CYCLE,              "cycle"),
    ("device_power",              DEVICE_POWER,              None),
]

out, missing, n = [], [], 0
out.append("# Home Assistant metric allowlist - phase 1 deliverable.\n"
           "#\n"
           "# This file IS the selection contract. Membership is reviewed by hand;\n"
           "# unit metadata is generated from HA so it cannot drift from reality.\n"
           "# Discovery by unit_class is an AUDIT that reports unclassified metrics,\n"
           "# never a mechanism that adds them.\n"
           "#\n"
           "# max_plausible_kw is sustained average power, not energy: multiplying by\n"
           "# bucket duration gives the kWh ceiling, so one value serves hourly,\n"
           "# daily and billing-period grains alike.\n")

for category, ids, role in groups:
    out.append(f"\n# ---- {category}"
               + (f" ({role})" if role else "")
               + f" : {len(ids)} ----")
    for sid in ids:
        if sid not in meta:
            missing.append(sid)
            continue
        unit, uclass, mtype, has_sum, source, ha_name = meta[sid]
        n += 1
        out.append("\n[[metric]]")
        out.append(f'statistic_id = "{sid}"')
        out.append(f'category = "{category}"')
        out.append(f'display_name = "{label(sid, ha_name)}"')
        out.append(f'source = "{source}"')
        out.append(f"unit_of_measurement = {tomlstr(unit)}")
        out.append(f"unit_class = {tomlstr(uclass)}")
        out.append(f"mean_type = {mtype if mtype is not None else 'false'}")
        out.append(f"has_sum = {'true' if has_sum else 'false'}")
        if role:
            out.append(f'energy_role = "{role}"')
            out.append(f"max_plausible_kw = {ceiling(sid)}")
        out.append(f"default_grain = \"hour\"")
        if sid in INACTIVE:
            out.append("is_active = false")

# --- reviewed exclusions, so the audit only alarms on NEW metrics ---------
allow = set()
for _c, _ids, _r in groups:
    allow |= set(_ids)

excl, unreviewed = [], []
for sid, (unit, uclass, mtype, has_sum, source, ha_name) in sorted(meta.items()):
    if uclass not in ("temperature", "power", "energy") and not sid.startswith("opower:"):
        continue
    if sid in allow:
        continue
    reason = exclusion_reason(sid, uclass)
    (excl if reason else unreviewed).append((sid, reason))

out.append(f"\n\n# ---- reviewed exclusions : {len(excl)} ----")
out.append("# Present in HA with a relevant unit_class, deliberately not exported.")
for sid, reason in excl:
    out.append("\n[[excluded]]")
    out.append(f'statistic_id = "{sid}"')
    out.append(f'reason = "{reason}"')

out.append("""

# ---- opower grain periods ----
# Half-open [valid_from, valid_until). Verified against row magnitudes,
# not spacing: 2025-11-14 has state=408.0 (a billing period), while
# 2025-11-15 has state=7.095 (the first true day).
# Expected partition: 75 billing_period / 26 day / 4919 hour = 5020.

[[grain_period]]
statistic_id = "opower:pgn_elec_6537807941_energy_consumption"
valid_from = "-infinity"
valid_until = "2025-11-15T08:00:00Z"
grain = "billing_period"

[[grain_period]]
statistic_id = "opower:pgn_elec_6537807941_energy_consumption"
valid_from = "2025-11-15T08:00:00Z"
valid_until = "2025-12-11T08:00:00Z"
grain = "day"

[[grain_period]]
statistic_id = "opower:pgn_elec_6537807941_energy_consumption"
valid_from = "2025-12-11T08:00:00Z"
valid_until = false
grain = "hour"
""")

sys.stdout.write("\n".join(out))
sys.stderr.write(f"\n[gen] {n} metrics, {len(excl)} reviewed exclusions; missing={missing}\n")
if unreviewed:
    sys.stderr.write(f"[gen] UNREVIEWED (audit would alarm): {unreviewed}\n")
    sys.exit(1)
