-- the settings' languages by sites' codes for them: MARC (ISO 639-2, both where there are two), as OPDS catalogues give
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

-- the names of the languages in each list given to names, worked out once a list (see names)
local names_of = setmetatable({}, { __mode = "k" })

-- each name to show of languages (each { code, text }), by what sites call it: its codes, name and code, lowercase
function LanguageCodes.names(languages)
    local names = names_of[languages]
    if not names then
        names = {}
        for __, language in ipairs(languages) do
            for __, code in ipairs(LanguageCodes.CODES[language.code] or {}) do
                names[code] = names[code] or language.text
            end
            names[language.text:lower()] = language.text
            names[language.code:lower()] = names[language.code:lower()] or language.text
        end
        names_of[languages] = names
    end
    return names
end

-- the one of languages (see names) a site's code or name for it is, or nil where it isn't one of them
function LanguageCodes.find(value, languages)
    local lower = type(value) == "string" and value:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    local names = LanguageCodes.names(languages)
    local name = names[lower] or names[lower:match("^(%a+)[-_]")]
    if not name then
        return nil
    end
    for __, language in ipairs(languages) do
        if language.text == name then
            return language
        end
    end
end

return LanguageCodes
