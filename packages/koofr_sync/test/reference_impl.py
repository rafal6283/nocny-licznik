# Niezależna implementacja formatu koofr_sync (Python) — źródło wektorów testowych dla Darta i Kotlina.
import base64, gzip, hashlib, hmac, json, os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey

SALT = b'koofr_sync v1'
ALPH = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
MAGIC = b'KSY1'

def hkdf(ikm, info, salt=SALT):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info.encode() if isinstance(info,str) else info).derive(ikm)

def b32(b):
    out=''; buf=0; bits=0
    for x in b:
        buf=(buf<<8)|x; bits+=8
        while bits>=5:
            bits-=5; out+=ALPH[(buf>>bits)&31]
        buf &= (1<<bits)-1
    if bits: out+=ALPH[(buf<<(5-bits))&31]
    return out

def fmt(ent):
    s=b32(ent+hashlib.sha256(ent).digest()[:2])
    return '-'.join(s[i:i+4] for i in range(0,len(s),4))

def keys(ent, app):
    m=hkdf(ent,'master'); bk=hkdf(m,'backup/'+app); seed=hkdf(m,'x25519/'+app); chk=hkdf(m,'check')[:8].hex()
    priv=X25519PrivateKey.from_private_bytes(seed)
    pub=priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return bk, priv, pub, chk

def seal_backup(bk, app, data, nonce):
    h=MAGIC+bytes([1])
    return h+nonce+AESGCM(bk).encrypt(nonce, gzip.compress(data, mtime=0), h+app.encode())

def seal_for(sender_priv, sender_pub, recip_pub, app, data, eph_seed, nonce):
    eph=X25519PrivateKey.from_private_bytes(eph_seed)
    ephpub=eph.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    rp=X25519PublicKey.from_public_bytes(recip_pub)
    ikm=eph.exchange(rp)+sender_priv.exchange(rp)
    k=hkdf(ikm, ('share/'+app).encode()+ephpub+sender_pub+recip_pub)
    h=MAGIC+bytes([2])
    return h+ephpub+nonce+AESGCM(k).encrypt(nonce, gzip.compress(data, mtime=0), h+app.encode())

def seal_exchange(ent, data, nonce):
    k=hkdf(hkdf(ent,'master'),'exchange')
    h=MAGIC+bytes([3])
    return h+nonce+AESGCM(k).encrypt(nonce, gzip.compress(data, mtime=0), h+b'wymiana')

def safety(app,a,b):
    ka=base64.urlsafe_b64encode(a).decode(); kb=base64.urlsafe_b64encode(b).decode()
    s=sorted([ka,kb])
    h=hashlib.sha256(('safety/%s/%s'%(app,'/'.join(s))).encode()).digest()
    n=int.from_bytes(h[:8],'big')%10**12
    t=str(n).zfill(12); return f'{t[:4]} {t[4:8]} {t[8:]}'

app='doba'
e1=bytes(range(1,19)); e2=bytes(range(101,119))
bk1,p1,pub1,c1=keys(e1,app); bk2,p2,pub2,c2=keys(e2,app)
v={
 'app':app,
 'owner':{'code':fmt(e1),'check':c1,'pub':base64.urlsafe_b64encode(pub1).decode(),'backupKey':bk1.hex()},
 'viewer':{'code':fmt(e2),'check':c2,'pub':base64.urlsafe_b64encode(pub2).decode()},
 'backup':seal_backup(bk1,app,'Doba — kopia testowa'.encode(),bytes(range(12))).hex(),
 'backupPlain':'Doba — kopia testowa',
 'share':seal_for(p1,pub1,pub2,app,'{"dni":[]}'.encode(),bytes(range(50,82)),bytes(range(20,32))).hex(),
 'sharePlain':'{"dni":[]}',
 'safety':safety(app,pub1,pub2),
 'exchange':seal_exchange(e1,'{"format":"wymiana-zdarzen"}'.encode(),bytes(range(40,52))).hex(),
 'exchangePlain':'{"format":"wymiana-zdarzen"}',
 'blobId':hmac.new(bk1,'załącznik'.encode(),hashlib.sha256).digest()[:16].hex(),
}
print(json.dumps(v, ensure_ascii=False, indent=1))
