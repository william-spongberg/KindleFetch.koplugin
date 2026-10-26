local KindleFetchSettings = require("settings.settings")

-- the languages the settings offer, by the codes sites give books' languages in: the MARC codes (ISO 639-2) of each,
-- with the two some languages have, as Internet Archive, Calibre-Web and other OPDS catalogues give most books',
-- besides its name and its code in the settings, which some give instead
local LanguageCodes = {}

-- the MARC codes of each language the settings offer, by its code in the settings
LanguageCodes.CODES = {
    en = { "eng" },
    es = { "spa" },
    fr = { "fre", "fra" },
    de = { "ger", "deu" },
    it = { "ita" },
    pt = { "por" },
    ru = { "rus" },
    zh = { "chi", "zho" },
    ja = { "jpn" },
    nl = { "dut", "nld" },
    bg = { "bul" },
    pl = { "pol" },
    ar = { "ara" },
    la = { "lat" },
    he = { "heb" },
    ["zh-Hant"] = { "chi", "zho" },
    tr = { "tur" },
    hu = { "hun" },
    cs = { "cze", "ces" },
    sv = { "swe" },
    da = { "dan" },
    ko = { "kor" },
    uk = { "ukr" },
    id = { "ind" },
    el = { "gre", "ell" },
    ro = { "rum", "ron" },
    lt = { "lit" },
    bn = { "ben" },
    ca = { "cat" },
    no = { "nor" },
    af = { "afr" },
    fi = { "fin" },
    hr = { "hrv" },
    sr = { "srp" },
    th = { "tha" },
    hi = { "hin" },
    ga = { "gle" },
    lv = { "lav" },
    fa = { "per", "fas" },
    vi = { "vie" },
    sk = { "slo", "slk" },
    kn = { "kan" },
    bo = { "tib", "bod" },
    cy = { "wel", "cym" },
    jv = { "jav" },
    ur = { "urd" },
    yi = { "yid" },
    hy = { "arm", "hye" },
    be = { "bel" },
    rw = { "kin" },
    ta = { "tam" },
    kk = { "kaz" },
    sl = { "slv" },
    ml = { "mal" },
    shn = { "shn" },
    mn = { "mon" },
    ka = { "geo", "kat" },
    mr = { "mar" },
    eo = { "epo" },
    et = { "est" },
    te = { "tel" },
    fil = { "fil" },
    gu = { "guj" },
    gl = { "glg" },
    ky = { "kir" },
    ms = { "may", "msa" },
    az = { "aze" },
    sw = { "swa" },
    qu = { "que" },
    pa = { "pan" },
    ba = { "bak" },
    sq = { "alb", "sqi" },
    uz = { "uzb" },
    bs = { "bos" },
    eu = { "baq", "eus" },
    my = { "bur", "mya" },
    am = { "amh" },
    ku = { "kur" },
    fy = { "fry" },
    zu = { "zul" },
    ps = { "pus" },
    ne = { "nep" },
    so = { "som" },
    ug = { "uig" },
    om = { "orm" },
    mk = { "mac", "mkd" },
    ht = { "hat" },
    lo = { "lao" },
    tt = { "tat" },
    si = { "sin" },
    ckb = { "ckb" },
    tg = { "tgk" },
    sn = { "sna" },
    su = { "sun" },
    nb = { "nob" },
    mg = { "mlg" },
    xh = { "xho" },
    ha = { "hau" },
    sd = { "snd" },
    ny = { "nya" },
}

-- what sites call each language, as each of its codes, its name and its code in the settings (all in small letters),
-- with the language's name to show
local names
function LanguageCodes.names()
    if not names then
        names = {}
        for __, language in ipairs(KindleFetchSettings:getAvailableLanguages()) do
            for __, code in ipairs(LanguageCodes.CODES[language.code] or {}) do
                names[code] = names[code] or language.text
            end
            names[language.text:lower()] = language.text
            names[language.code:lower()] = names[language.code:lower()] or language.text
        end
    end
    return names
end

-- the language a site's code or name for it is, e.g. "eng", "en-GB" or "English", with its code in the settings and
-- its name, or nil when the settings don't offer it
function LanguageCodes.find(value)
    local lower = type(value) == "string" and value:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    local name = LanguageCodes.names()[lower] or LanguageCodes.names()[lower:match("^(%a+)[-_]")]
    if not name then
        return nil
    end
    for __, language in ipairs(KindleFetchSettings:getAvailableLanguages()) do
        if language.text == name then
            return language
        end
    end
end

return LanguageCodes
