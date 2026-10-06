"""Test signers of the local stand: private key = the number below as 32 bytes; addresses verified with
devshard/signing at devshard/v5.0.2. They only ever sign on the mock chain."""

HOST_FIRST = 0x1001
USER_NUMBER = 0x21
USER_ADDRESS = "gonka1hyejskh022pxjq4t6vkr6uyzgdrqjhthec9dqf"
HOST_ADDRESSES = (
    "gonka1gyxufc9wkae0xqnfk0qpdqguu0dnldm544z62j",
    "gonka1x6dsypj8veykxuhq7gn7c7yeurtncsmnkdjzf6",
    "gonka102u56gf54lyw77cw8rua7jxzap9rp2qk4pg85h",
    "gonka1r989qd3x6enz0hna353hfdfy2q985xchvsepr9",
    "gonka1q8z80gcqudx97k4z8ge2jc0wtv0fvd555469zt",
    "gonka1vyezz554nhn2gds75yupyfpv9gr900748yeelk",
    "gonka1xhhuaqegwv7enc54rp98sz8juqlhs2emmqn5cc",
    "gonka13vchahsu8k6c4gsy0q0yufy4z2scyunru5mx7t",
    "gonka1aeet887q00m96efyyefcgudddm34hw7dahv5qp",
    "gonka19zwz8yzaefkqzy7fwfdz3em8epvk4027hnpph6",
    "gonka1lltyafdlrknk7c7dl6ayj7v4yccr3vk02dsw52",
    "gonka1gmwkkhqrdcpxjk94t30tuhh5w73tfykxhuygs4",
    "gonka12jnuv8ekrfm7y9e5a02e9u8agx5hhsudytkqe5",
    "gonka1edaedzs8thyw94w05w838r89pkdypc0rr7va0q",
    "gonka10th6xfrfmfw4y4juahjatxlktnmcntl3e5fylk",
    "gonka1cmk8dernzts59m95zfjt9janttsppskwn9v6rt",
    "gonka1qswztrgsk6l5nc9cvwgr0wlyddhjkhgn7yj06v",
    "gonka15q3wa3hfpdzx8fcpfh3hxlmhrw6g2dxt3drhsg",
    "gonka1atsv36zcc9ymcv0hzj4s6u5yw8ntyxgkwv8zxf",
    "gonka155zgwydv2sjwryaqp7uqn692036sfc84x3zax7",
    "gonka1r2h3pd07sxwqknjxwcaq8qwdw82mydfft3kyq0",
    "gonka1ws9m7gh7mv5ckzjthdtr7g3dzy4zles660ndh0",
    "gonka1udjfzcm40hymsjsdpta60acp3amt4ulrgwk27a",
    "gonka1gja9h5p7djckg0yq3z9v70q36x60ae26nyqz8u",
    "gonka15w002d73exmgk9arhtnfw8caa2t62f5sfvwqle",
    "gonka1he0w7wwv0xdwgwewglvwy7r8m440urdasmkxdp",
    "gonka1j70pdy32k5g08qrw8mq0ew5nzhc7hfjjlm9vp5",
    "gonka1jrjj3wa0ww2f6rjzrupm7qd7alyay52jw4d49m",
    "gonka1h49lqrrzmyehdk0vmce49tg0rce09pgdzxmkq8",
    "gonka1t3r3f0ynz0nz6n7hrljajdv3fehzz9qqny6lpv",
    "gonka19tge26hcz4hzhuqadwhyz4q4wc8wk6dgxxaw9p",
    "gonka196t2t953j0sthgehx8lx7dgs2xnhw4tghczeq9",
    "gonka1m4xf8c9zdlg48sp87hl0pfkws3j44thflsxzvd",
    "gonka100jznlw7tvelfm7t8yh5rdvtljzly0tgj4fwuf",
    "gonka19thrhq6dyscr7pzh2taju6qpd9fgkaldtuw53m",
    "gonka1kpk56yqmja58dxtyu36jsq26mfat9gzh9aquta",
    "gonka14q4tm4ed3ekmc2xh7g844ypnxcn249k39q93ad",
    "gonka1pn0l0sxe54wc63hrwjd8x8jqz2jqqtd8ev80fg",
    "gonka108fwtw05e0lcwgsj0antd3qetq5phhr2flz7ge",
    "gonka15hlqt84hu3gz694ks6e8jfmtayynn7e5vgjw7p",
    "gonka1ghfg0fgdd7pe20sz6dmttcscv3qvvpakkrm5ey",
    "gonka19mm39ft272479j5vumqzryhsxrup34yht2gs8s",
    "gonka143kr0kspkt23lh75flfpmxeae6rwhfd3psguu8",
    "gonka1slrql4ya4cdyts9cfzltepmd3pjrgfq6phrnwy",
    "gonka1z46twkhmdhxj9wwrv3kg43pvjv5mqknmqpcp2z",
    "gonka1qvkwkvrkxjvvt3xqgeh2pwmyeyx7aq24vj7u8c",
    "gonka1c0y5xqc25xpztn37kkna4ksnx7y0dhk4s35aec",
    "gonka1lzrvetngn2v6meq5zf94cagu5avmh2gg24q768",
    "gonka1xpm7ejxfp98w0afa97t3g2cl3u3w0l5putfx5c",
    "gonka1hpqz8nhn46wrw66x6sf0j0mamueag9gcmmyxjp",
    "gonka1rcapskdksayfdkktda5wv3xswykrkjznetfne2",
    "gonka1qp547jjg0at3av5h9z57cckdrqjw43uknlxxyp",
    "gonka13nc908m07a7d2gyzmx50r6pctvn4gz99n2s4ut",
    "gonka1mwme27rdhapnfrac59t8q204n4r8h60gmhyuma",
    "gonka10j2xfsnrqkqevhgvxyzuagsqvhf7rdqm0fuwu3",
    "gonka134ape0daau777nttzws6rv3jxv25fnyhykgrqv",
    "gonka1vexuf5533pn5ddaqsr2nu4u26e3hpuz5wmlcza",
    "gonka1l2jxvuag8v4l5f62xc2kvydl094la9l2cetkg9",
    "gonka1fttsly24x04m42khyk0ragpynsfx3krqk3typd",
    "gonka1yshjzyf2egldejznx986ka5fkc0npfv0htj648",
    "gonka1zq0n6qxq2w0gg4pvwda6aqfuqnjts06234lx5z",
    "gonka1fvu7kjx46rjxjjlcy5y2kpg7g8zcej4ty6uhe7",
    "gonka1u7jm22sv7uxazka2xk8wpcghyhrwvy4xwj9z8q",
    "gonka19ys95k4m6x3g3z8qc92j7w03777mxfp6rfzny4",
)


def private_key(number):
    return "%064x" % number


def host(j):
    """(private key hex, address) of stand host j."""
    return private_key(HOST_FIRST + j), HOST_ADDRESSES[j]
